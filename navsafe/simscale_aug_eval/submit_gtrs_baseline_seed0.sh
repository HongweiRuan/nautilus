#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="$HERE/gtrs_baseline_seed0.yaml"
kubectl apply --dry-run=server -f "$MANIFEST" >/dev/null
kubectl apply -f "$MANIFEST"
kubectl get jobs -n cogrob -l navsafe-batch=gtrs-baseline-seed0
