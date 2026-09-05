#!/bin/bash
# Apply one manifest, waiting out the Nautilus utilisation policy.
set -uo pipefail
cd "$(dirname "$0")"
F=${1:?usage: requeue_any.sh templates/<file>.yaml}
while :; do
  if out=$(kubectl apply -f "$F" 2>&1); then echo "[$(date +%H:%M:%S)] $out"; break; fi
  case "$out" in
    *utilization*|*denied\ the\ request*) echo "[$(date +%H:%M:%S)] refused; retry in 180s";;
    # A transport hiccup is not a bad manifest. `failed to download openapi`
    # killed the six-car queue after two hours of waiting, on one unreachable
    # API server, and nothing was submitted.
    *"no route to host"*|*"connection refused"*|*timeout*|*"i/o timeout"*|*"failed to download openapi"*)
      echo "[$(date +%H:%M:%S)] API unreachable; retry in 60s"; sleep 60; continue;;
    *) echo "[$(date +%H:%M:%S)] FAILED: $out"; exit 1;;
  esac
  sleep 180
done
