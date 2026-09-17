#!/usr/bin/env bash
set -euo pipefail
MODEL=$(basename "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)")
kubectl get job,pod -n cogrob -l "app=navsafe-env-perturb,model=$MODEL" -o wide
