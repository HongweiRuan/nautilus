#!/usr/bin/env bash
# Submit the NavSafe 12-leaf eval sweep: one Job per (model, seed), 12 models
# x 3 seeds = 36 jobs. Each job loops over all 12 leaves' scenarios (126
# tokens) against the shared navsafe-eval-nurec renderer.
#
#   ./submit_eval.sh                 submit all 36 jobs
#   MODELS=drivor ./submit_eval.sh   submit just one model, all 3 seeds
#   SEEDS="1" ./submit_eval.sh       submit just seed 1, all models
#   DRYRUN=1 ./submit_eval.sh        render into rendered/ but don't apply
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

NS=cogrob
TEMPLATE=templates/eval_pod.yaml
MODELS_TSV=models.tsv
SEEDS="${SEEDS:-1 2 3}"
FILTER_MODELS="${MODELS:-}"

mkdir -p rendered

while IFS=$'\t' read -r MODEL MODEL_TYPE CKPT EXTRA_ENV; do
  [[ "$MODEL" =~ ^#.*$ || -z "$MODEL" ]] && continue
  if [ -n "$FILTER_MODELS" ] && [[ ! " $FILTER_MODELS " == *" $MODEL "* ]]; then
    continue
  fi
  EXTRA_ENV="${EXTRA_ENV:-__NOOP__=1}"
  # models.tsv extra_env is comma-separated KEY=VAL pairs; bash `export` takes
  # space-separated assignments, so translate commas to spaces here.
  EXTRA_ENV_SPACED="${EXTRA_ENV//,/ }"

  for SEED in $SEEDS; do
    OUT="rendered/navsafe-eval-${MODEL}-seed${SEED}.yaml"
    sed \
      -e "s|__MODEL__|${MODEL}|g" \
      -e "s|__MODEL_TYPE__|${MODEL_TYPE}|g" \
      -e "s|__CHECKPOINT__|${CKPT}|g" \
      -e "s|__EXTRA_ENV__|${EXTRA_ENV_SPACED}|g" \
      -e "s|__SEED__|${SEED}|g" \
      "$TEMPLATE" > "$OUT"

    if [ -n "${DRYRUN:-}" ]; then
      echo "[dryrun] rendered $OUT"
    else
      kubectl apply -f "$OUT"
    fi
  done
done < "$MODELS_TSV"

echo "done."
