#!/usr/bin/env bash
# submit_stage.sh <ncore|aux|arrow|train>
#
# Finds every clip MISSING this stage's output on CephFS, packs them into as few
# shards as the namespace quota allows, and submits ONE job per shard — each job loops
# over its clips. So a whole stage usually finishes in a SINGLE submission.
#
# Nautilus caps CONCURRENTLY ACTIVE pods per namespace (NS_LIMIT, default 200);
# terminal Completed/Failed pods do not count. The script measures what is active,
# keeps RESERVE (20) free for other people, and sizes clips-per-job so the remaining
# backlog fits in the jobs it is allowed to create.
#
# Sharding also removes the per-clip container overhead: ncore/arrow build a venv and
# pip-install (~4 min) and arrow copies the 1.4G HD maps — with shards that is paid
# once per job instead of once per clip.
#
# Idempotent: every template skips clips whose output already exists, and clips that
# are already Running/Pending are excluded, so re-running only picks up stragglers.
# The CephFS "what's done" check runs via `kubectl exec` into POD (the Mac can't read
# CephFS); `kubectl apply` runs with your local kubectl (that is the account whose
# Nautilus utilization is scored).
#
#   ./submit_stage.sh ncore                 # one submission covers the whole stage
#   JOBS=100 ./submit_stage.sh aux          # cap shards below the quota (fewer, longer jobs)
#   PER_JOB=4 ./submit_stage.sh train       # fix clips-per-job instead of letting it auto-size
#   RESERVE=50 ./submit_stage.sh arrow      # leave more room for other people
#   DRYRUN=1 ./submit_stage.sh train        # render rendered/<stage>/*.yaml, don't apply
#
# Per-clip runtimes (measured): ncore ~9 min, aux ~17 min, arrow ~5 min, train ~4.5 h.
# So auto-sizing train to fill the quota gives very long jobs — use PER_JOB to bound
# them. A preempted shard only loses the clip in flight: every finished clip has already
# copied its last.usdz to CephFS, and a resubmit skips whatever is there.
#
# Stage order: ncore -> aux -> arrow -> train   (aux and arrow need only ncore.)
set -uo pipefail
cd "$(dirname "$0")"

STAGE="${1:-}"
case "$STAGE" in ncore|aux|arrow|train) ;; *)
  echo "usage: [JOBS= PER_JOB= POD= DRYRUN=1] $0 <ncore|aux|arrow|train>"; exit 1;; esac

NS="${NS:-cogrob}"
POD="${POD:-horuan-nexussim}"
NS_LIMIT="${NS_LIMIT:-200}"                  # Nautilus: max concurrently ACTIVE pods per namespace
RESERVE="${RESERVE:-20}"                     # leave this many for other people in the namespace
JOBS="${JOBS:-}"                             # hard cap on shards; default = whatever the quota allows
ROOT=/avl-west/navsafe_5s_500
TSV="${TSV:-scenes_500.tsv}"                 # token \t log \t t0 \t t1 \t types \t leaves \t source
TPL="templates/${STAGE}.yaml"
SEG=5000000                                  # exact 5 s clips
# Shard names carry a per-run id. A Job's spec.template is IMMUTABLE, and shard N of
# this run holds different clips than shard N of the last one, so reusing names makes
# `kubectl apply` fail with "field is immutable". Unique names sidestep it entirely
# (and remove the need to delete-then-apply, which raced with --wait=false).
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"

[ -f "$TSV" ] || { echo "!! $TSV missing — run select_500.py on a pod first"; exit 1; }
[ -f "$TPL" ] || { echo "!! $TPL missing"; exit 1; }

# 1) expand scenarios -> clips (clip \t log \t ct0 \t ct1)
CLIPS=$(mktemp)
awk -F'\t' -v SEG="$SEG" 'NF>=4 && $1!~/^#/ {
  for (k=1;k<=4;k++){ printf "%ss%d\t%s\t%d\t%d\n",$1,k,$2,$3+(k-1)*SEG,$3+k*SEG }
}' "$TSV" > "$CLIPS"
NTOTAL=$(wc -l < "$CLIPS" | tr -d ' ')

# 2) which clips already have this stage's output? (one pod exec)
case "$STAGE" in
  ncore) GLOB="$ROOT/*/clips/*/pai_*.json";               SED='s#.*/clips/([^/]+)/pai_.*#\1#' ;;
  aux)   GLOB="$ROOT/*/clips/*/*.aux.*.zarr.itar";         SED='s#.*/clips/([^/]+)/[^/]+\.aux\..*#\1#' ;;
  arrow) GLOB="$ROOT/*/arrow/logs/nuplan_test/*";          SED='s#.*/arrow/logs/nuplan_test/([^/]+)$#\1#' ;;
  train) GLOB="$ROOT/*/output_5cam/*/artifacts/last.usdz"; SED='s#.*/output_5cam/([^/]+)/artifacts/.*#\1#' ;;
esac
DONE=$(mktemp)
# NOTE: this exec is the ONLY source of truth for "what is already built". If POD is
# dead the exec fails, and silently swallowing that made done=0 -> the whole backlog
# got re-submitted. Fail loudly instead: a wrong done count mis-schedules hundreds of
# jobs (they no-op thanks to the per-clip skip in the template, but waste slots).
if ! kubectl exec -n "$NS" "$POD" -- bash -lc "ls -d $GLOB 2>/dev/null" > "$DONE".raw 2>"$DONE".err; then
  echo "!! cannot read CephFS through pod '$POD' — gap-check impossible, refusing to submit."
  echo "   $(head -1 "$DONE".err)"
  echo "   fix: kubectl get pod -n $NS $POD    (recreate it, or pass POD=<another pod>)"
  rm -f "$CLIPS" "$DONE" "$DONE".raw "$DONE".err; exit 1
fi
sed -E "$SED" < "$DONE".raw | sort -u > "$DONE"; rm -f "$DONE".raw "$DONE".err
NDONE=$(grep -c . "$DONE")

# 3) clips already in flight. Read the clip list straight out of each live job's spec
#    (the manifest is embedded in the container args), NOT from local rendered/*.clips:
#    those files live under an iCloud-synced folder that renames them on conflict
#    ("sh000 3.clips"), which silently made inflight=0 and caused duplicate assignment.
#    Reading the cluster also means a resubmit from another machine still sees the truth.
INFLIGHT=$(mktemp)
kubectl get jobs -n "$NS" -l "app=navsafe_5s_500,stage=$STAGE" -o json 2>/dev/null \
| python3 -c '
import sys, json, re
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
out = set()
for j in d.get("items", []):
    if not j.get("status", {}).get("active"):      # only jobs with a live pod
        continue
    try: args = j["spec"]["template"]["spec"]["containers"][0]["args"][0]
    except Exception: continue
    m = re.search(r"<<.MANIFEST_EOF.\n(.*?)\nMANIFEST_EOF", args, re.S)
    if not m: continue
    for line in m.group(1).splitlines():
        t = line.split()
        if t: out.add(t[0])
print("\n".join(sorted(out)))
' > "$INFLIGHT"
NRUN=$(grep -c . "$INFLIGHT")

# 4) missing = clips - done - inflight
MISSING=$(mktemp)
comm -23 <(cut -f1 "$CLIPS" | sort -u) <(cat "$DONE" "$INFLIGHT" | sort -u) | grep . > "$MISSING" || true
NMISS=$(grep -c . "$MISSING")

echo "[$STAGE] clips=$NTOTAL  done=$NDONE  inflight=$NRUN  missing=$NMISS"
if [ "$NMISS" -eq 0 ]; then
  echo "[$STAGE] STAGE COMPLETE — nothing to submit."
  rm -f "$CLIPS" "$DONE" "$INFLIGHT" "$MISSING"; exit 0
fi

# --- namespace quota: Nautilus caps CONCURRENTLY ACTIVE pods (Running+Pending) per
# --- namespace. Completed/Failed pods are terminal and do not count. Every job we
# --- create makes a pod immediately (Pending if there is no capacity), so the number
# --- of shards we may submit is bounded by what is left of the quota.
ACTIVE=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
         | awk '$3=="Running"||$3=="Pending"||$3=="ContainerCreating"' | wc -l | tr -d ' ')
BUDGET=$(( NS_LIMIT - RESERVE - ACTIVE ))
[ -n "$JOBS" ] && [ "$JOBS" -lt "$BUDGET" ] && BUDGET=$JOBS
echo "[$STAGE] namespace quota: limit=$NS_LIMIT reserve=$RESERVE active=$ACTIVE -> may submit $BUDGET job(s)"
if [ "$BUDGET" -le 0 ]; then
  echo "[$STAGE] no quota free right now — wait for running jobs to drain, then re-run."
  rm -f "$CLIPS" "$DONE" "$INFLIGHT" "$MISSING"; exit 0
fi

# clips per job: pack the whole backlog into the jobs we are allowed to create
PER=${PER_JOB:-$(( (NMISS + BUDGET - 1) / BUDGET ))}
[ "${PER:-0}" -lt 1 ] && PER=1
NSHARD=$(( (NMISS + PER - 1) / PER ))
[ "$NSHARD" -gt "$BUDGET" ] && NSHARD=$BUDGET          # never exceed the quota
COVER=$(( NSHARD * PER )); [ "$COVER" -gt "$NMISS" ] && COVER=$NMISS
echo "[$STAGE] -> $NSHARD job(s) x $PER clip(s) = $COVER of $NMISS clip(s) this round"
if [ "$STAGE" = "train" ]; then
  echo "[train] ~$(( PER * 27 / 6 ))h per job at ~4.5h/clip — bound it with PER_JOB= if that is too long."
fi
[ "$COVER" -lt "$NMISS" ] && echo "[$STAGE] NOTE: $((NMISS - COVER)) clip(s) left over — re-run after this batch drains."

# 5) render one yaml per shard (manifest lines are indented to match the YAML block)
OUT="rendered/${STAGE}"; mkdir -p "$OUT"
# keep older shard manifests: the in-flight check above reads them to learn which clips
# a still-running shard owns. Prune only what is long finished.
find "$OUT" -type f -mtime +3 -delete 2>/dev/null || true
NEWYAMLS=$(mktemp)
python3 - "$TPL" "$CLIPS" "$MISSING" "$OUT" "$PER" "$NSHARD" "$RUNID" "$NEWYAMLS" <<'PY'
import os, sys, math, re
tpl_p, clips_p, miss_p, out_d = sys.argv[1:5]
per, nshard = int(sys.argv[5]), int(sys.argv[6])
runid, newlist = sys.argv[7], sys.argv[8]
tpl = open(tpl_p).read()
rows = {}
for line in open(clips_p):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 4: rows[f[0]] = (f[1], f[2], f[3])
missing = [l.strip() for l in open(miss_p) if l.strip()]
# indentation of the __MANIFEST__ line inside the YAML block scalar
m = re.search(r'^([ \t]*)__MANIFEST__', tpl, re.M)
indent = m.group(1) if m else ""
n = 0
for i in range(0, min(len(missing), per * nshard), per):
    shard = missing[i:i+per]
    name = "sh%03d-%s" % (i // per, runid)
    manifest = "\n".join(f"{indent}{c} {rows[c][0]} {rows[c][1]} {rows[c][2]}"
                         for c in shard if c in rows)
    y = (tpl.replace(indent + "__MANIFEST__", manifest)
            .replace("__SHARD__", name)
            .replace("__STRUCTLIDAR__", os.environ.get("STRUCT_LIDAR", "1")))
    open(f"{out_d}/{name}.yaml", "w").write(y)
    open(f"{out_d}/{name}.clips", "w").write("\n".join(shard) + "\n")
    open(newlist, "a").write(f"{out_d}/{name}.yaml\n")
    n += 1
print(f"rendered {n} shard yaml(s)")
PY

if [ -n "${DRYRUN:-}" ]; then
  echo "[$STAGE] DRYRUN: not applying (see $OUT/)"; rm -f "$CLIPS" "$DONE" "$INFLIGHT" "$MISSING"; exit 0
fi

# 6) apply ONLY this run's shards (names are unique, so no immutable-spec conflicts)
xargs -n1 kubectl apply -f < "$NEWYAMLS"
echo "[$STAGE] submitted $NSHARD job(s) covering $COVER of $NMISS missing clip(s)."
echo "         watch:  kubectl get pods -n $NS -l app=navsafe_5s_500,stage=$STAGE"
echo "         re-run this script when they finish to pick up any failures."
rm -f "$CLIPS" "$DONE" "$INFLIGHT" "$MISSING" "${NEWYAMLS:-}"
