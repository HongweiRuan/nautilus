#!/usr/bin/env bash
set -euo pipefail
NAMESPACE=${NAMESPACE:-cogrob}
kubectl get job -n "$NAMESPACE" navsafe-full-eval-simscale
kubectl get pods -n "$NAMESPACE" -l navsafe-batch=full-eval-simscale \
  -o custom-columns=NAME:.metadata.name,INDEX:.metadata.annotations.batch\.kubernetes\.io/job-completion-index,PHASE:.status.phase,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount
