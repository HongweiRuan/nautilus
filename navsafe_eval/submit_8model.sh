#!/usr/bin/env bash
# Submit the 11-row NavSafe eval sweep (5 host models + 6 VLA rows; SimWAM
# excluded, see models.tsv) as ONE indexed Job for the given seed --
# parallelism 26 x 2 GPU = 52, the account's full GPU cap. Submit ONE seed
# at a time: k8s does not cap parallelism across separately-submitted Jobs,
# so two seeds running together would ask for 104 GPUs.
#
#   SEED=1 ./submit_8model.sh          submit seed 1
#   SEED=2 DRYRUN=1 ./submit_8model.sh render into rendered/ but don't apply
#
# Before submitting, check GPU budget isn't already spoken for by another
# campaign in this namespace:
#   kubectl get pods -n cogrob --no-headers | grep -v Completed | \
#     awk '{print $1}' | grep -v ^navsafe-eval-8model
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${SEED:?usage: SEED=<1|2|3> ./submit_8model.sh}"
NS=cogrob
TEMPLATE=indexed_job_8model_template.yaml
CFG=navsafe-eval-cfg-8model

mkdir -p rendered

OUT="rendered/navsafe-eval-8model-seed${SEED}.yaml"
sed "s|__SEED__|${SEED}|g" "$TEMPLATE" > "$OUT"

if [ -n "${DRYRUN:-}" ]; then
  echo "[dryrun] rendered $OUT"
else
  # ConfigMap must exist and carry the current run_worker.sh/models.tsv --
  # this script does not (re)create it, since editing the eval logic is a
  # separate, deliberate step from submitting a run against it.
  kubectl get configmap "$CFG" -n "$NS" >/dev/null
  kubectl apply -f "$OUT"
fi

echo "done."
