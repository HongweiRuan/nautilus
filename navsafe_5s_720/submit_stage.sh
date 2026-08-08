#!/usr/bin/env bash
# submit_stage.sh <ncore|aux|arrow|train>
#
# For the 720 selected scenarios (each quartered into four EXACT 5s clips s1..s4 =
# 2880 clips), find the clips MISSING this stage's output on CephFS, render their
# job yamls, and `kubectl apply` up to BATCH (default 180) at once.
#
# Idempotent: re-run to drain the queue — finished clips are skipped, running/pending
# ones aren't resubmitted. The Mac can't read CephFS, so the "what's done" check runs
# via `kubectl exec` into a pod that mounts /avl-west (POD, default horuan-nexussim);
# the `kubectl apply` runs with your local kubectl (i.e. YOUR account -> the account
# whose util-policy is checked).
#
#   ./submit_stage.sh ncore              # submit up to 180 missing-ncore clips
#   BATCH=180 ./submit_stage.sh aux
#   DRYRUN=1 ./submit_stage.sh train     # render into rendered/<stage>/, don't apply
#   POD=some-other-pod ./submit_stage.sh arrow
#
# Stage order (each waits on the previous): ncore -> aux -> arrow -> train
#   (arrow only needs ncore; aux only needs ncore; train needs aux.)
set -uo pipefail
cd "$(dirname "$0")"

STAGE="${1:-}"
case "$STAGE" in ncore|aux|arrow|train) ;; *)
  echo "usage: [BATCH= POD= DRYRUN=1] $0 <ncore|aux|arrow|train>"; exit 1;; esac

NS="${NS:-cogrob}"
POD="${POD:-horuan-nexussim}"
BATCH="${BATCH:-180}"
ROOT=/avl-west/navsafe-5s-720
TSV="${TSV:-scenes_720.tsv}"                 # token \t log \t t0 \t t1 \t type \t source
TPL="templates/${STAGE}.yaml"
SEG=5000000                                  # 5.000s segments from t0 (drops the ~1.5s tail)

[ -f "$TSV" ] || { echo "!! $TSV missing — run select_720.py on a pod first"; exit 1; }
[ -f "$TPL" ] || { echo "!! $TPL missing"; exit 1; }

# 1) expand the 720 tokens -> 2880 clips (clipid \t log \t ct0 \t ct1)
CLIPS=$(mktemp)
awk -F'\t' -v SEG="$SEG" 'NF>=4 && $1!~/^#/ {
  for (k=1;k<=4;k++){ ct0=$3+(k-1)*SEG; ct1=$3+k*SEG; printf "%ss%d\t%s\t%d\t%d\n",$1,k,$2,ct0,ct1 }
}' "$TSV" > "$CLIPS"
NTOTAL=$(wc -l < "$CLIPS" | tr -d ' ')

# 2) which clips already have this stage's output on CephFS? (one pod exec, glob-based)
case "$STAGE" in
  ncore) GLOB="$ROOT/*/clips/*/pai_*.json";              SED='s#.*/clips/([^/]+)/pai_.*#\1#' ;;
  aux)   GLOB="$ROOT/*/clips/*/*.aux.*.zarr.itar";        SED='s#.*/clips/([^/]+)/[^/]+\.aux\..*#\1#' ;;
  arrow) GLOB="$ROOT/*/arrow/logs/nuplan_test/*";         SED='s#.*/arrow/logs/nuplan_test/([^/]+)$#\1#' ;;
  train) GLOB="$ROOT/*/output_5cam/*/artifacts/last.usdz";SED='s#.*/output_5cam/([^/]+)/artifacts/.*#\1#' ;;
esac
DONE=$(mktemp)
kubectl exec -n "$NS" "$POD" -- bash -lc "ls -d $GLOB 2>/dev/null" 2>/dev/null \
  | sed -E "$SED" | sort -u > "$DONE"
NDONE=$(grep -c . "$DONE")

# 3) clips already running/pending for this stage (don't resubmit)
INFLIGHT=$(mktemp)
kubectl get pods -n "$NS" -l "app=navsafe-5s-720,stage=$STAGE" \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.labels.scene}{"\n"}{end}{range .items[?(@.status.phase=="Pending")]}{.metadata.labels.scene}{"\n"}{end}' 2>/dev/null \
  | sort -u | grep . > "$INFLIGHT" || true
NRUN=$(grep -c . "$INFLIGHT")

# 4) missing = clips - done - inflight
MISSING=$(mktemp)
comm -23 <(cut -f1 "$CLIPS" | sort -u) <(cat "$DONE" "$INFLIGHT" | sort -u) | grep . > "$MISSING" || true
NMISS=$(grep -c . "$MISSING")

echo "[$STAGE] clips=$NTOTAL  done=$NDONE  inflight=$NRUN  missing=$NMISS  -> submitting up to $BATCH"

# 5) render + apply up to BATCH of the missing
OUT="rendered/${STAGE}"; rm -rf "$OUT"; mkdir -p "$OUT"
n=0
while IFS= read -r C; do
  [ "$n" -ge "$BATCH" ] && break
  row=$(awk -F'\t' -v c="$C" '$1==c{print; exit}' "$CLIPS"); [ -z "$row" ] && continue
  LOG=$(echo "$row" | cut -f2); CT0=$(echo "$row" | cut -f3); CT1=$(echo "$row" | cut -f4)
  sed -e "s|__SCENE__|$C|g" -e "s|__LOG__|$LOG|g" -e "s|__T0__|$CT0|g" -e "s|__T1__|$CT1|g" \
      "$TPL" > "$OUT/$C.yaml"
  n=$((n+1))
done < "$MISSING"
echo "[$STAGE] rendered $n job yaml(s) -> $OUT/"

if [ -n "${DRYRUN:-}" ]; then
  echo "[$STAGE] DRYRUN: not applying"; rm -f "$CLIPS" "$DONE" "$INFLIGHT" "$MISSING"; exit 0
fi
if [ "$n" -gt 0 ]; then
  # delete any stale terminal job of the same name (immutable fields block re-apply), then apply
  for f in "$OUT"/*.yaml; do
    kubectl delete job -n "$NS" "nav720-${STAGE}-$(basename "$f" .yaml)" --ignore-not-found --wait=false >/dev/null 2>&1
  done
  kubectl apply -f "$OUT"/
  echo "[$STAGE] submitted $n job(s). Re-run to submit the next $BATCH once these drain."
else
  echo "[$STAGE] nothing to submit — stage complete or all inflight."
fi
rm -f "$CLIPS" "$DONE" "$INFLIGHT" "$MISSING"
