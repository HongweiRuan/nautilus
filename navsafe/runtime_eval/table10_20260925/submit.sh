#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 generate_jobs.py
kubectl create configmap navsafe-table10-20260925-cfg -n cogrob \
  --from-file=run_worker.sh --from-file=models.tsv --from-file=instrument_timing.py \
  --dry-run=client -o yaml > configmap.generated.yaml
{ cat configmap.generated.yaml; echo '---'; cat jobs.base.yaml; } > jobs.yaml
kubectl apply --dry-run=server -f jobs.yaml
kubectl apply -f jobs.yaml
kubectl get jobs -n cogrob -l app=navsafe-table10-20260925
