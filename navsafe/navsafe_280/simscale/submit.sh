#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$HERE/preflight.sh"
kubectl apply --dry-run=server -f "$HERE/jobs.yaml" >/dev/null
kubectl apply -f "$HERE/jobs.yaml"
kubectl get jobs -n cogrob -l navsafe-batch=simscale-aug
