#!/usr/bin/env bash
# Bulk-launch ONE pipeline stage for ALL navhard scenes at once, by plugging
# each scene's (token, log, t0, t1) into templates/<stage>.yaml and kubectl-apply.
# Each ~20s scenario is split into two ~10s halves (h1/h2) trained separately, so
# 421 scenarios => 842 jobs per stage. SPLIT=0 keeps whole scenes.
#
# This is the "fire all N at once, saturate every GPU" model: one `kubectl apply`
# per scene (or a single -f on the rendered dir), no serial per-scene waiting.
#
#   ./run_stage.sh <stage>
#     stage = ncore | arrow | aux | train | export | eval
#
# Env:
#   TSV=scenes.tsv     scene manifest (token \t log \t t0_us \t t1_us)
#   LIMIT=N            only the first N scenes (smoke test)
#   STAGGER=SEC        sleep SEC between applies (throttle to dodge util-policy
#                      burst cooldown); default 0 = apply the whole rendered dir
#   DRYRUN=1           render into rendered/<stage>/ but do NOT apply
#
# Stage order (each stage waits for the previous to finish — see status.sh):
#   ncore -> (arrow ∥ aux) -> train -> export -> eval
#   arrow is independent of aux/train; run it any time before eval.
set -euo pipefail
cd "$(dirname "$0")"

STAGE="${1:-}"
case "$STAGE" in ncore|arrow|aux|train|export|eval) ;; *)
  echo "usage: [TSV= LIMIT= STAGGER= DRYRUN=1] $0 <ncore|arrow|aux|train|export|eval>"; exit 1;; esac

TSV="${TSV:-scenes.tsv}"
TPL="templates/${STAGE}.yaml"
[ -f "$TPL" ] || { echo "!! missing template $TPL"; exit 1; }
[ -f "$TSV" ] || { echo "!! missing manifest $TSV"; exit 1; }

OUT="rendered/${STAGE}"
rm -rf "$OUT"; mkdir -p "$OUT"

# Each ~20s navhard scenario is split into a first-half + second-half ~10s clip
# (midpoint split), trained/rendered independently. Set SPLIT=0 to keep whole
# scenes. Halves get suffixed tokens h1/h2 so they are distinct scenes end to end
# (distinct ncore stores, usdz scene_ids, job names) -> 421 scenarios => 842 jobs.
emit () {  # <scene_id> <t0> <t1>
  sed -e "s|__SCENE__|$1|g" -e "s|__LOG__|$LOG|g" \
      -e "s|__T0__|$2|g"   -e "s|__T1__|$3|g" "$TPL" > "$OUT/$1.yaml"
}

# Optional whitelist for resubmits: ONLY=<file> lists the split scene-ids (one per
# line, e.g. "087023402a695ba3h1") to (re)emit; every other scene is skipped. Used
# to re-run just the failed/never-run subset without touching completed scenes.
USE_ONLY=0                                   # (grep-based; works on macOS bash 3.2)
if [ -n "${ONLY:-}" ]; then
  [ -f "$ONLY" ] || { echo "!! ONLY list not found: $ONLY"; exit 1; }
  USE_ONLY=1
  echo "[$STAGE] ONLY filter: $(grep -c . "$ONLY") scene id(s) from $ONLY"
fi
want () { [ "$USE_ONLY" -eq 0 ] && return 0; grep -qxF "$1" "$ONLY"; }

n=0; j=0
while IFS=$'\t' read -r C LOG T0 T1; do
  [ -z "${C:-}" ] && continue
  case "$C" in \#*) continue;; esac
  if [ "${SPLIT:-1}" != "0" ]; then
    MID=$(( T0 + (T1 - T0) / 2 ))          # midpoint -> two equal ~10s halves
    if want "${C}h1"; then emit "${C}h1" "$T0"  "$MID"; j=$((j+1)); fi
    if want "${C}h2"; then emit "${C}h2" "$MID" "$T1";  j=$((j+1)); fi
  else
    if want "$C"; then emit "$C" "$T0" "$T1"; j=$((j+1)); fi
  fi
  n=$((n+1))
  [ -n "${LIMIT:-}" ] && [ "$n" -ge "$LIMIT" ] && break
done < "$TSV"
echo "[$STAGE] rendered $j job yaml(s) from $n scenario(s) -> $OUT/  (SPLIT=${SPLIT:-1})"

[ -n "${DRYRUN:-}" ] && { echo "[$STAGE] DRYRUN: not applying"; exit 0; }

# REPLACE=1 -> delete any existing Job of the same name before applying, so a
# resubmit is idempotent (a completed/failed Job has immutable fields that would
# otherwise make `kubectl apply` fail; a running one is torn down and restarted).
NS="${NS:-cogrob}"
replace_one () { [ -n "${REPLACE:-}" ] && kubectl delete job -n "$NS" "navhard-${STAGE}-$1" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }

if [ -n "${STAGGER:-}" ] && [ "${STAGGER}" != "0" ]; then
  echo "[$STAGE] applying $j jobs, ${STAGGER}s apart ${REPLACE:+(REPLACE: deleting stale jobs first) }..."
  i=0
  for f in "$OUT"/*.yaml; do
    replace_one "$(basename "$f" .yaml)"
    kubectl apply -f "$f" >/dev/null && i=$((i+1))
    sleep "$STAGGER"
  done
  echo "[$STAGE] applied $i/$j"
else
  if [ -n "${REPLACE:-}" ]; then
    echo "[$STAGE] REPLACE: deleting stale jobs ..."
    for f in "$OUT"/*.yaml; do replace_one "$(basename "$f" .yaml)"; done
  fi
  echo "[$STAGE] applying all $j jobs at once ..."
  kubectl apply -f "$OUT"/
fi
echo "[$STAGE] submitted. watch with:  ./status.sh $STAGE"
