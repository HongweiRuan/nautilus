#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAMESPACE=${NAMESPACE:-cogrob}
CONFIGMAP=navsafe-full-eval-simscale-cfg
JOB=navsafe-full-eval-simscale
python3 "$HERE/validate.py"
kubectl create configmap "$CONFIGMAP" -n "$NAMESPACE" \
  --from-file=run_worker.sh="$HERE/run_worker.sh" \
  --from-file=gtrs_dense.py="$HERE/gtrs_dense.py" \
  --from-file=models.tsv="$HERE/models.tsv" \
  --from-file=full_test_tokens.txt="$HERE/full_test_tokens.txt" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --dry-run=server -n "$NAMESPACE" -f "$HERE/job.yaml" >/dev/null
if [[ ${1:-} == --replace ]]; then
  kubectl delete job "$JOB" -n "$NAMESPACE" --ignore-not-found --wait=true
fi
kubectl create -n "$NAMESPACE" -f "$HERE/job.yaml"
kubectl get job "$JOB" -n "$NAMESPACE"
