#!/bin/bash
# Submit one already-rendered manifest, waiting out the utilisation policy.
set -uo pipefail
cd "$(dirname "$0")"
NAME=${1:?usage: requeue_one.sh <job-name>}
BACKOFF=${BACKOFF:-240}
while :; do
  if out=$(kubectl apply -f "rendered/$NAME.yaml" 2>&1); then
    echo "[$(date +%H:%M:%S)] accepted $NAME"; break
  fi
  case "$out" in
    *utilization*|*denied\ the\ request*)
      echo "[$(date +%H:%M:%S)] refused; retrying in ${BACKOFF}s";;
    *) echo "[$(date +%H:%M:%S)] FAILED: $out"; exit 1;;
  esac
  sleep "$BACKOFF"
done
