#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kubectl apply -f "$HERE/jobs.yaml"
kubectl get jobs -n cogrob -l navsafe-batch=simscale-aug
