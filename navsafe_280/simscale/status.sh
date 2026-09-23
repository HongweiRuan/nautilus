#!/usr/bin/env bash
set -euo pipefail
kubectl get jobs -n cogrob -l navsafe-batch=simscale-aug \
  -o custom-columns=NAME:.metadata.name,ACTIVE:.status.active,SUCCEEDED:.status.succeeded,FAILED:.status.failed,AGE:.metadata.creationTimestamp
echo
kubectl get pods -n cogrob -l navsafe-batch=simscale-aug \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount
