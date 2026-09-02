#!/usr/bin/env bash
# submit_stage.sh <ncore|aux|arrow|train>
#
# Same shape as navsafe_5s_500/submit_stage.sh, with three deliberate differences:
#
#   1. SHARDING IS BY SCENARIO, NOT BY CLIP. The ask was "7 train jobs, 2 scenarios
#      each, serial". A scenario is 4 x 5 s clips, so a train shard runs 8 clips back
#      to back. Every stage uses the same 7 x 2 split so a shard means the same thing
#      everywhere and the four stages line up one-to-one.
#
#   2. ARROW IS PER 20 s HOST, NOT PER 5 s CLIP. navsafe_5s_500 expanded every stage
#      to <token>s1..s4, but arrow's own output lands at <token>_20s/arrow and its
#      done-glob reads the inner scene name — so that check never matched and the
#      stage looked permanently un-built (14 stray per-clip arrows in the corpus are
#      the residue). leaves/hosts.py globs <CORPUS>/*_20s/arrow, so <token>_20s is
#      the id that has to exist.
#
#   3. NO GPU WHERE NONE IS NEEDED. ncore and arrow are CPU work; they no longer carry
#      the nvidia.com/gpu.product node affinity that pinned them to GPU nodes. aux and
#      train still request nvidia.com/gpu: 1. All four pin to the cogrob-reserved
#      ry-gpu 3090s minus ry-gpu-13/14.
#
# OUTPUT GOES TO THE navsafe_5s_500 CORPUS. These 13 scenarios are the same shape as
# the ones already there (nuPlan test split, navsim 5-cam rig, 20 s cut into 4 x 5 s),
# and nexussim/navsafe/leaves/hosts.py discovers hosts by globbing cfg.CORPUS/*_20s/
# arrow. Writing them anywhere else makes them invisible to `navsafe bake` and eval
# without a new corpus root. Same corpus, more scenarios.
#
#   ./submit_stage.sh ncore            # 7 jobs x 2 scenarios (8 clips each)
#   DRYRUN=1 ./submit_stage.sh train   # render rendered/<stage>/*.yaml, do not apply
#   SHARDS=4 ./submit_stage.sh aux     # fewer, longer jobs
#
# Per-clip runtimes (measured on navsafe_5s_500): ncore ~9 min, aux ~17 min,
# arrow ~5 min/host, train ~4.5 h. So a train shard of 8 clips is ~36 h. That is
# survivable: every finished clip copies last.usdz to CephFS before the next starts,
# backoffLimit is 6, and a resubmit skips whatever is already there.
#
# Stage order: ncore -> aux -> train.  arrow needs only the nuPlan DB, so it can run
# any time, in parallel with ncore.
set -uo pipefail
cd "$(dirname "$0")"

STAGE="${1:-}"
case "$STAGE" in ncore|aux|arrow|train) ;; *)
  echo "usage: [SHARDS= POD= DRYRUN=1] $0 <ncore|aux|arrow|train>"; exit 1;; esac

NS="${NS:-cogrob}"
POD="${POD:-horuan-nexussim}"
APP=illegal_turn_recon
ROOT=/avl-west/navsafe_5s_500          # same corpus as navsafe_5s_500 — see header
TSV="${TSV:-scenes.tsv}"               # token \t log \t t0 \t t1 \t turn \t dyaw \t lanes \t city
TPL="templates/${STAGE}.yaml"
SHARDS="${SHARDS:-7}"
SEG=5000000                            # exact 5 s clips
# A Job's spec.template is immutable and shard N of this run holds different work than
# shard N of the last, so names carry a per-run id rather than being reused.
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"

[ -f "$TSV" ] || { echo "!! $TSV missing"; exit 1; }
[ -f "$TPL" ] || { echo "!! $TPL missing"; exit 1; }

# 1) scenarios -> this stage's work units (unit \t log \t t0 \t t1 \t scenario)
UNITS=$(mktemp)
awk -F'\t' -v SEG="$SEG" -v STAGE="$STAGE" 'NF>=4 && $1!~/^#/ {
  if (STAGE == "arrow") { printf "%s_20s\t%s\t%d\t%d\t%s\n", $1,$2,$3,$4,$1 }
  else { for (k=1;k<=4;k++)
           printf "%ss%d\t%s\t%d\t%d\t%s\n", $1,k,$2,$3+(k-1)*SEG,$3+k*SEG,$1 }
}' "$TSV" > "$UNITS"
NSCEN=$(cut -f5 "$UNITS" | sort -u | wc -l | tr -d ' ')
NTOTAL=$(wc -l < "$UNITS" | tr -d ' ')

# 2) which units already have this stage's output? (one pod exec)
case "$STAGE" in
  ncore) GLOB="$ROOT/*/clips/*/pai_*.json";               SED='s#.*/clips/([^/]+)/pai_.*#\1#' ;;
  aux)   GLOB="$ROOT/*/clips/*/*.aux.*.zarr.itar";        SED='s#.*/clips/([^/]+)/[^/]+\.aux\..*#\1#' ;;
  arrow) GLOB="$ROOT/*_20s/arrow/maps";                   SED='s#.*/([^/]+)/arrow/maps$#\1#' ;;
  train) GLOB="$ROOT/*/output_5cam/*/artifacts/last.usdz"; SED='s#.*/output_5cam/([^/]+)/artifacts/.*#\1#' ;;
esac
DONE=$(mktemp)
# This exec is the ONLY source of truth for "what is already built". A dead pod must
# fail loudly: a silent done=0 resubmits the whole backlog.
if ! kubectl exec -n "$NS" "$POD" -- bash -lc "ls -d $GLOB 2>/dev/null" > "$DONE".raw 2>"$DONE".err; then
  echo "!! cannot read CephFS through pod '$POD' — gap-check impossible, refusing to submit."
  echo "   $(head -1 "$DONE".err)"
  echo "   fix: kubectl get pod -n $NS $POD    (recreate it, or pass POD=<another pod>)"
  rm -f "$UNITS" "$DONE" "$DONE".raw "$DONE".err; exit 1
fi
sed -E "$SED" < "$DONE".raw | sort -u > "$DONE"; rm -f "$DONE".raw "$DONE".err

# 3) units already in flight — read from each live job's embedded manifest, so a
#    resubmit from another machine still sees the truth.
INFLIGHT=$(mktemp)
kubectl get jobs -n "$NS" -l "app=$APP,stage=$STAGE" -o json 2>/dev/null \
| python3 -c '
import sys, json, re
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
out = set()
for j in d.get("items", []):
    if not j.get("status", {}).get("active"):
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

# 4) missing = units - done - inflight
MISSING=$(mktemp)
comm -23 <(cut -f1 "$UNITS" | sort -u) <(cat "$DONE" "$INFLIGHT" | sort -u) | grep . > "$MISSING" || true
NMISS=$(grep -c . "$MISSING")
echo "[$STAGE] scenarios=$NSCEN units=$NTOTAL done=$(grep -c . "$DONE") inflight=$(grep -c . "$INFLIGHT") missing=$NMISS"
if [ "$NMISS" -eq 0 ]; then
  echo "[$STAGE] STAGE COMPLETE — nothing to submit."
  rm -f "$UNITS" "$DONE" "$INFLIGHT" "$MISSING"; exit 0
fi

# 5) group missing units by SCENARIO, chunk scenarios into SHARDS jobs, render, apply
OUT="rendered/${STAGE}"; mkdir -p "$OUT"
# Clear the previous render of this stage. Safe: the in-flight check above reads the
# live jobs' embedded manifests from the cluster, never these files. Without this a
# retry loop (chain.sh re-renders every 5 min while the admission webhook refuses)
# buries the directory in thousands of dead shard yamls — and this tree is
# iCloud-synced, which renames files on conflict and has broken a run before.
rm -f "$OUT"/*.yaml "$OUT"/*.units 2>/dev/null || true
NEWYAMLS=$(mktemp)
python3 - "$TPL" "$UNITS" "$MISSING" "$OUT" "$SHARDS" "$RUNID" "$NEWYAMLS" "$STAGE" <<'PY'
import os, sys, re, math
tpl_p, units_p, miss_p, out_d = sys.argv[1:5]
nshard, runid, newlist, stage = int(sys.argv[5]), sys.argv[6], sys.argv[7], sys.argv[8]

rows, scen_of = {}, {}
for line in open(units_p):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 5:
        rows[f[0]] = (f[1], f[2], f[3]); scen_of[f[0]] = f[4]
missing = [l.strip() for l in open(miss_p) if l.strip()]

# scenario -> its still-missing units, in the TSV's order
order, by_scen = [], {}
for u in sorted(missing, key=lambda u: (scen_of[u], u)):
    s = scen_of[u]
    if s not in by_scen:
        by_scen[s] = []; order.append(s)
    by_scen[s].append(u)

per = max(1, math.ceil(len(order) / nshard))     # scenarios per job
chunks = [order[i:i + per] for i in range(0, len(order), per)]
print(f"[{stage}] {len(order)} scenario(s) -> {len(chunks)} job(s) x <= {per} scenario(s)")

tpl = open(tpl_p).read()
m = re.search(r'^([ \t]*)__MANIFEST__', tpl, re.M)
indent = m.group(1) if m else ""
for i, chunk in enumerate(chunks):
    units = [u for s in chunk for u in by_scen[s]]
    name = "sh%03d-%s" % (i, runid)
    manifest = "\n".join(f"{indent}{u} {rows[u][0]} {rows[u][1]} {rows[u][2]}" for u in units)
    y = (tpl.replace(indent + "__MANIFEST__", manifest)
            .replace("__SHARD__", name)
            .replace("__STRUCTLIDAR__", os.environ.get("STRUCT_LIDAR", "1")))
    open(f"{out_d}/{name}.yaml", "w").write(y)
    open(f"{out_d}/{name}.units", "w").write("\n".join(units) + "\n")
    open(newlist, "a").write(f"{out_d}/{name}.yaml\n")
    print(f"   {name}: {len(chunk)} scenario(s), {len(units)} unit(s)  {' '.join(chunk)}")
PY

if [ -n "${DRYRUN:-}" ]; then
  echo "[$STAGE] DRYRUN: not applying (see $OUT/)"
  rm -f "$UNITS" "$DONE" "$INFLIGHT" "$MISSING" "$NEWYAMLS"; exit 0
fi

# xargs keeps going after a rejected apply, so count what actually landed rather
# than announcing success unconditionally — the Nautilus admission webhook denies
# every job when the account's utilization is under policy, and a blanket
# "submitted" there is a lie that costs hours before anyone notices.
NAPPLY=0; NDENY=0
while read -r y; do
  if kubectl apply -f "$y"; then NAPPLY=$((NAPPLY+1)); else NDENY=$((NDENY+1)); fi
done < "$NEWYAMLS"
if [ "$NDENY" -gt 0 ]; then
  echo "[$STAGE] $NAPPLY applied, $NDENY REJECTED — nothing to watch for the rejected ones."
  echo "         re-run this script once the rejection clears; it is idempotent."
  rm -f "$UNITS" "$DONE" "$INFLIGHT" "$MISSING" "$NEWYAMLS"; exit 1
fi
echo "[$STAGE] submitted $NAPPLY job(s). watch: kubectl get pods -n $NS -l app=$APP,stage=$STAGE"
rm -f "$UNITS" "$DONE" "$INFLIGHT" "$MISSING" "$NEWYAMLS"
