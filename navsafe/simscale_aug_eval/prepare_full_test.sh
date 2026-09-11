#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

kubectl delete job navsafe-full-test-prepare -n cogrob --ignore-not-found=true
kubectl create configmap navsafe-full-test-prepare \
  -n cogrob \
  --from-file=prepare_full_test.py=prepare_full_test.py \
  --dry-run=client -o yaml > .prepare-full-test-configmap.yaml
kubectl apply -f .prepare-full-test-configmap.yaml
kubectl apply --server-side --dry-run=server -f prepare-full-test.yaml >/dev/null
kubectl apply -f prepare-full-test.yaml
kubectl get job navsafe-full-test-prepare -n cogrob
echo "Monitor with: kubectl logs -n cogrob -f job/navsafe-full-test-prepare"
