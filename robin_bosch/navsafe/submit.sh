#!/usr/bin/env bash
# ./submit.sh            full run: 20 workers x 2 GPUs over the 280 scenarios
# ./submit.sh --smoke    one worker, 2 scenarios, all 4 models (separate OUTROOT)
# ./submit.sh --smoke-pp the same smoke with the pure_pursuit controller instead of lqr
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAMESPACE=${NAMESPACE:-cogrob}
CONFIGMAP=robin-drivor-action-navsafe-cfg
JOB=robin-drivor-action-navsafe; FILE=$HERE/job.yaml
if [[ ${1:-} == --smoke ]]; then JOB=robin-drivor-action-navsafe-smoke; FILE=$HERE/job-smoke.yaml; fi
if [[ ${1:-} == --smoke-pp ]]; then JOB=robin-drivor-action-navsafe-smoke-pp; FILE=$HERE/job-smoke-pp.yaml; fi
python3 "$HERE/validate.py" "$FILE"
kubectl create configmap "$CONFIGMAP" -n "$NAMESPACE" \
  --from-file=run_worker.sh="$HERE/run_worker.sh" \
  --from-file=drivor_action.py="$HERE/drivor_action.py" \
  --from-file=models.tsv="$HERE/models.tsv" \
  --from-file=models_drivor.tsv="$HERE/models_drivor.tsv" \
  --from-file=full_test_tokens.txt="$HERE/full_test_tokens.txt" \
  --from-file=proxy28_tokens.txt="$HERE/proxy28_tokens.txt" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --dry-run=server -n "$NAMESPACE" -f "$FILE" >/dev/null
kubectl create -n "$NAMESPACE" -f "$FILE"
kubectl get job "$JOB" -n "$NAMESPACE"
