#!/usr/bin/env bash
# Submit the NavSafe 8model eval sweep as WORKERS independent Jobs (default 20),
# each on 2 GPUs, sharded by scenario. Replaces the single indexed
# navsafe-eval-8model-seed<N> Job.
#
#   ./submit_8model.sh                    seed 1, 20 jobs
#   SEED=4 ./submit_8model.sh             seed 4, 20 jobs
#   SEED=4 WORKERS=12 ./submit_8model.sh  seed 4, 12 jobs (24 GPUs)
#   DRYRUN=1 ./submit_8model.sh           render into rendered_8model/, don't apply
#   ONLY="w03 w17" ./submit_8model.sh     resubmit just those shards
#
# Nodes are restricted to ry-gpu-05/06/07/08/11/12 (48 GPUs); 13 and 14 are
# left for other users. WORKERS x 2 must stay <= 48.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NS=cogrob
TEMPLATE=templates/worker_job_8model.yaml
WORKERS="${WORKERS:-20}"
SEED="${SEED:-1}"
ONLY="${ONLY:-}"
OUTDIR=rendered_8model/seed${SEED}

if [ "$(( WORKERS * 2 ))" -gt 48 ]; then
  echo "refusing: WORKERS=$WORKERS needs $(( WORKERS * 2 )) GPUs, only 48 on the six allowed nodes" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

APPLIED=0
for ((i = 0; i < WORKERS; i++)); do
  W=$(printf 'w%02d' "$i")
  if [ -n "$ONLY" ] && [[ ! " $ONLY " == *" $W "* ]]; then
    continue
  fi
  OUT="$OUTDIR/navsafe-eval-8model-s${SEED}-${W}.yaml"
  sed \
    -e "s|__WIDX__|${i}|g" \
    -e "s|__W__|${W}|g" \
    -e "s|__SEED__|${SEED}|g" \
    -e "s|__WORKERS__|${WORKERS}|g" \
    "$TEMPLATE" > "$OUT"

  if [ -n "${DRYRUN:-}" ]; then
    echo "[dryrun] rendered $OUT"
  else
    kubectl -n "$NS" apply -f "$OUT"
    APPLIED=$(( APPLIED + 1 ))
  fi
done

if [ -z "${DRYRUN:-}" ]; then
  echo "applied $APPLIED jobs (seed $SEED, WORKERS=$WORKERS, $(( APPLIED * 2 )) GPUs)"
fi
