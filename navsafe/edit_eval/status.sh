#!/bin/bash
# Where the campaign is: job states, per-shard progress, and what failed.
set -uo pipefail
cd "$(dirname "$0")"
NS=${NS:-cogrob}
OUTROOT=${OUTROOT:-/avl-west/runs/20260907-edit24-handoff8}
POD=${POD:-}   # a pod with /avl-west mounted, for the on-disk half

echo "=== jobs ==="
kubectl get jobs -n "$NS" -l app=navsafe-editeval -o wide 2>/dev/null
echo
echo "=== pods ==="
kubectl get pods -n "$NS" -l 'k8s-app in (navsafe-editeval-w00,navsafe-editeval-w01,navsafe-editeval-w02,navsafe-editeval-w03,navsafe-editeval-w04)' -o wide 2>/dev/null
echo
for i in 0 1 2 3 4; do
  NAME=navsafe-editeval-w$(printf %02d $i)
  P=$(kubectl get pods -n "$NS" -l "k8s-app=$NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$P" ] || { echo "--- $NAME: no pod"; continue; }
  echo "--- $NAME ($P)"
  kubectl logs -n "$NS" "$P" -c sim --tail=3 2>/dev/null | sed 's/^/    /'
done
if [ -n "$POD" ]; then
  echo
  echo "=== on disk ($OUTROOT) ==="
  kubectl exec -n "$NS" "$POD" -- bash -lc "
    d=$OUTROOT
    echo \"  done:   \$(ls -d \$d/*/.done 2>/dev/null | wc -l) of $(grep -vc '^[[:space:]]*#' scenarios.txt)\"
    echo \"  gifs:   \$(ls \$d/*/visualization/combined.gif 2>/dev/null | wc -l)\"
    grep -l FAILED \$d/logs/*.log 2>/dev/null | head" 2>/dev/null
fi
