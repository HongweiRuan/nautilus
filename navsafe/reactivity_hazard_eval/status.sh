#!/usr/bin/env bash
set -euo pipefail
kubectl get job -n cogrob navsafe-reactivity-hazard-v1 -o wide
kubectl get pods -n cogrob -l app=navsafe-reactivity-hazard -o wide
kubectl get pods -n cogrob -l app=navsafe-reactivity-hazard -o json | jq -r '.items[] | [.metadata.name,.status.phase,([.status.containerStatuses[]?.state.terminated.exitCode] | join(",")),(.status.containerStatuses[0].state.waiting.reason // ""),(.spec.nodeName // "")] | @tsv'
