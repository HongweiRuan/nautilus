#!/bin/bash
# What each of the sixteen is doing, and how much footage it has produced.
set -eo pipefail
cd "$(dirname "$0")"
OUTROOT=${OUTROOT:-/avl-west/runs/20260902-paper-figure2-drivor}
POD=${POD:-horuan-nexussim}
kubectl get jobs -n cogrob -l app=navsafe-figure2 \
  -o custom-columns=NAME:.metadata.name,DONE:.status.succeeded,FAIL:.status.failed,AGE:.metadata.creationTimestamp
echo
echo "--- footage on the PVC ($OUTROOT) ---"
kubectl exec -n cogrob "$POD" -- bash -c '
for d in '"$OUTROOT"'/*/; do
  [ -d "$d/frames" ] || continue
  printf "%-30s %4s frames   %s   %s\n" "$(basename "$d")" \
    "$(ls -1 "$d/frames" 2>/dev/null | wc -l)" \
    "$([ -f "$d/visualization/combined.mp4" ] && echo "mp4 " || echo "no mp4")" \
    "$([ -f "$d/.done" ] && echo done || echo running)"
done' 2>/dev/null || echo "(pod $POD unavailable)"
