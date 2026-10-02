#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kubectl create configmap navsafe-v8-nooverlay-20260923-r1-r1-cfg -n cogrob \
  --from-file=run_worker.sh="$HERE/run_worker.sh" \
  --from-file=tokens.txt="$HERE/tokens.txt" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --dry-run=server -f "$HERE/job.yaml" >/dev/null
kubectl create -f "$HERE/job.yaml"
kubectl get job -n cogrob navsafe-v8-nooverlay-20260923-r1
