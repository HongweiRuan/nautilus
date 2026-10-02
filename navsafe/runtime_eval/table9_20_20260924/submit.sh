#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
kubectl create configmap navsafe-table9-runtime-20260924-cfg -n cogrob \
  --from-file=run_worker.sh --from-file=models.tsv \
  --dry-run=client -o yaml > configmap.generated.yaml
{ cat configmap.generated.yaml; echo '---'; cat jobs.base.yaml; } > jobs.yaml
kubectl apply --dry-run=server -f jobs.yaml
kubectl apply -f jobs.yaml
kubectl get jobs -n cogrob -l app=navsafe-table9-runtime-20260924
