#!/usr/bin/env bash
# submit_stage.sh <infos|render_native|drivearena|score>
#
# NavSafe NuRec vs DriveArena on the scenarios we have reconstructions for.
# The frame set is pinned once by build_manifest.py; every stage reads it, so the
# two renderers cover the same frames by construction rather than by agreement.
#
# Shape (same as navsafe_5s_500/submit_stage.sh, for the same reasons):
#   * finds what is MISSING, packs it into as few shards as the namespace pod quota
#     allows, ONE job per shard, each looping over its work. Not an indexed Job.
#   * shard names carry a run id: a Job's spec.template is IMMUTABLE, so reusing a
#     name makes `kubectl apply` fail with "field is immutable".
#   * the done-check runs via `kubectl exec` into POD because the Mac cannot read
#     CephFS. An empty result is normal on the first run; only a dead pod blocks a
#     submission, which is why the probe prints a sentinel.
#
#   ./submit_stage.sh infos              # once, ~20 min, CPU
#   ./submit_stage.sh render_native      # NuRec 1920x1080 -- NavSafe's real policy input
#   ./submit_stage.sh drivearena         # WorldDreamer 400x224 -- its only output size
#   JOBS=20 PER_JOB=10 DRYRUN=1 ./submit_stage.sh drivearena
#
# render_native shards by CLIP (4 per scenario, ~70 s each, independent).
# drivearena shards by SCENARIO and never within one: generation is autoregressive
# and the reference resets at a scenario boundary, so splitting one changes its output.
set -uo pipefail
cd "$(dirname "$0")"

STAGE="${1:-}"
case "$STAGE" in infos|score|render_native|drivearena) ;; *)
  echo "usage: [JOBS= PER_JOB= POD= DRYRUN=1] $0 <infos|render_native|drivearena|score>"; exit 1;; esac

NS="${NS:-cogrob}"
POD="${POD:-horuan-nexussim}"
NS_LIMIT="${NS_LIMIT:-200}"
RESERVE="${RESERVE:-20}"
JOBS="${JOBS:-20}"
RQE=/avl-west/render_quality_eval
TPL="templates/${STAGE}.yaml"
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"
[ -f "$TPL" ] || { echo "!! $TPL missing"; exit 1; }

# --- infos is a single un-sharded job -------------------------------------------
if [ "$STAGE" = "infos" ] || [ "$STAGE" = "score" ]; then
  if [ -z "${DRYRUN:-}" ]; then
    kubectl delete job -n "$NS" "rqe-$STAGE" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl apply -f "$TPL"
    echo "[$STAGE] submitted.  watch: ./status.sh"
  else
    echo "[$STAGE] DRYRUN: would apply $TPL"
  fi
  exit 0
fi

# --- probe the pod and learn what is already done --------------------------------
probe() {  # $1 = shell snippet listing done ids on stdout
  local raw err; raw=$(mktemp); err=$(mktemp)
  kubectl exec -n "$NS" "$POD" -- bash -lc "$1; echo __PROBE_OK__" >"$raw" 2>"$err"
  if ! grep -q __PROBE_OK__ "$raw"; then
    echo "!! cannot read CephFS through pod '$POD' — refusing to submit." >&2
    echo "   $(head -1 "$err")" >&2
    echo "   fix: kubectl get pod -n $NS $POD" >&2
    rm -f "$raw" "$err"; return 1
  fi
  grep -v __PROBE_OK__ "$raw" | grep . || true
  rm -f "$raw" "$err"
}

WANT=$(mktemp); DONE=$(mktemp)
case "$STAGE" in
  render_native)
    SUB=nurec_native
    probe "python3 -c \"
import json
m=json.load(open('$RQE/manifest.json'))['scenarios']
print('\n'.join(s['sid']+'s'+str(k) for s in m for k in (1,2,3,4)))\"" > "$WANT" || exit 1
    probe "ls -d $RQE/render_raw/$SUB/*/camera_pcam_f0 2>/dev/null" \
      | sed -E 's#.*/([^/]+)/camera_pcam_f0$#\1#' | sort -u > "$DONE" || exit 1
    UNIT=clip; SECS=70 ;;
  drivearena)
    probe "python3 -c \"
import json
m=json.load(open('$RQE/manifest.json'))['scenarios']
print('\n'.join(s['sid'] for s in m))\"" > "$WANT" || exit 1
    # a scenario is done when every one of its manifest frames has a jpg
    probe "python3 -c \"
import json,os
R='$RQE/render_raw/drivearena'
m=json.load(open('$RQE/manifest.json'))['scenarios']
for s in m:
    if all(os.path.exists(os.path.join(R,f['data_path'])) for f in s['frames']):
        print(s['sid'])\"" | sort -u > "$DONE" || exit 1
    UNIT=scenario; SECS=510 ;;
esac
sort -u -o "$WANT" "$WANT"
NTOTAL=$(grep -c . "$WANT"); NDONE=$(grep -c . "$DONE")

# in-flight work, read out of the live jobs' specs (local files live under an
# iCloud-synced dir that renames on conflict and silently double-assigns)
INFLIGHT=$(mktemp)
kubectl get jobs -n "$NS" -l "app=render_quality_eval,stage=$STAGE" -o json 2>/dev/null \
| python3 -c '
import sys, json, re
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
out = set()
for j in d.get("items", []):
    if not j.get("status", {}).get("active"): continue
    try: args = j["spec"]["template"]["spec"]["containers"][0]["args"][0]
    except Exception: continue
    m = re.search(r"<<.MANIFEST_EOF.\n(.*?)\nMANIFEST_EOF", args, re.S)
    if not m: continue
    for line in m.group(1).splitlines():
        t = line.split()
        if t: out.add(t[0])
print("\n".join(sorted(out)))' > "$INFLIGHT"
NRUN=$(grep -c . "$INFLIGHT")

MISSING=$(mktemp)
comm -23 "$WANT" <(cat "$DONE" "$INFLIGHT" | sort -u) | grep . > "$MISSING" || true
NMISS=$(grep -c . "$MISSING")
echo "[$STAGE] ${UNIT}s=$NTOTAL  done=$NDONE  inflight=$NRUN  missing=$NMISS"
[ "$NMISS" -eq 0 ] && { echo "[$STAGE] STAGE COMPLETE."; rm -f "$WANT" "$DONE" "$INFLIGHT" "$MISSING"; exit 0; }

ACTIVE=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
         | awk '$3=="Running"||$3=="Pending"||$3=="ContainerCreating"' | wc -l | tr -d ' ')
BUDGET=$(( NS_LIMIT - RESERVE - ACTIVE ))
[ -n "$JOBS" ] && [ "$JOBS" -lt "$BUDGET" ] && BUDGET=$JOBS
echo "[$STAGE] quota: limit=$NS_LIMIT reserve=$RESERVE active=$ACTIVE -> may submit $BUDGET job(s)"
[ "$BUDGET" -le 0 ] && { echo "[$STAGE] no quota free — wait and re-run."; \
  rm -f "$WANT" "$DONE" "$INFLIGHT" "$MISSING"; exit 0; }

PER=${PER_JOB:-$(( (NMISS + BUDGET - 1) / BUDGET ))}
[ "${PER:-0}" -lt 1 ] && PER=1
NSHARD=$(( (NMISS + PER - 1) / PER )); [ "$NSHARD" -gt "$BUDGET" ] && NSHARD=$BUDGET
COVER=$(( NSHARD * PER )); [ "$COVER" -gt "$NMISS" ] && COVER=$NMISS
echo "[$STAGE] -> $NSHARD job(s) x $PER $UNIT(s) = $COVER of $NMISS  (~$(( PER * SECS / 60 )) min per job)"
[ "$COVER" -lt "$NMISS" ] && echo "[$STAGE] NOTE: $((NMISS - COVER)) left over — re-run after this batch drains."

OUT="rendered/${STAGE}"; mkdir -p "$OUT"
find "$OUT" -type f -mtime +3 -delete 2>/dev/null || true
NEW=$(mktemp)
python3 - "$TPL" "$MISSING" "$OUT" "$PER" "$NSHARD" "$RUNID" "$NEW" <<'PY'
import sys, re
tpl_p, miss_p, out_d = sys.argv[1:4]
per, nshard, runid, newlist = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6], sys.argv[7]
tpl = open(tpl_p).read()
missing = [l.strip() for l in open(miss_p) if l.strip()]
m = re.search(r'^([ \t]*)__MANIFEST__', tpl, re.M)
indent = m.group(1) if m else ""
n = 0
for i in range(0, min(len(missing), per * nshard), per):
    shard = missing[i:i+per]
    name = "sh%03d-%s" % (i // per, runid)
    y = tpl.replace(indent + "__MANIFEST__", "\n".join(indent + c for c in shard))
    y = y.replace("__SHARD__", name)
    open(f"{out_d}/{name}.yaml", "w").write(y)
    open(newlist, "a").write(f"{out_d}/{name}.yaml\n")
    n += 1
print(f"rendered {n} shard yaml(s)")
PY
if [ -n "${DRYRUN:-}" ]; then
  echo "[$STAGE] DRYRUN: not applying (see $OUT/)"
  rm -f "$WANT" "$DONE" "$INFLIGHT" "$MISSING"; exit 0
fi
xargs -n1 kubectl apply -f < "$NEW"
echo "[$STAGE] submitted $NSHARD job(s) covering $COVER of $NMISS $UNIT(s)."
echo "         watch: ./status.sh"
rm -f "$WANT" "$DONE" "$INFLIGHT" "$MISSING" "${NEW:-}"
