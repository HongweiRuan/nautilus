#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
kubectl apply --dry-run=server -f render_scope_fix.yaml
kubectl apply -f render_scope_fix.yaml
kubectl get jobs -n cogrob -l navsafe-batch=simscale-aug-scope-fix
