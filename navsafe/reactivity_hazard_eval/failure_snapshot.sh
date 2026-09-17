#!/usr/bin/env bash
set -euo pipefail
for p in $(kubectl get pods -n cogrob -l app=navsafe-reactivity-hazard -o jsonpath='{.items[*].metadata.name}'); do
  phase=$(kubectl get pod -n cogrob "$p" -o jsonpath='{.status.phase}')
  [ "$phase" = Failed ] || continue
  echo "===== $p ====="
  kubectl get pod -n cogrob "$p" -o jsonpath='reason={.status.reason} message={.status.message}{"\n"}exit={.status.containerStatuses[0].state.terminated.exitCode} term_reason={.status.containerStatuses[0].state.terminated.reason}{"\n"}'
  kubectl logs -n cogrob "$p" -c eval --tail=160 || true
done
