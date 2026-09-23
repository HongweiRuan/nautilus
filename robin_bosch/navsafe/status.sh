#!/usr/bin/env bash
set -euo pipefail
NAMESPACE=${NAMESPACE:-cogrob}
kubectl get job -n "$NAMESPACE" robin-drivor-action-navsafe
kubectl get pods -n "$NAMESPACE" -l navsafe-batch=robin-drivor-action \
  -o custom-columns=NAME:.metadata.name,INDEX:.metadata.annotations.batch\.kubernetes\.io/job-completion-index,PHASE:.status.phase,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount
