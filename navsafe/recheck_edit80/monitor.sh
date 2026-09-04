#!/bin/bash
# Watch the six shards, convert finished footage, and say what is wrong.
#
# It does NOT restart anything on its own. A shard that fails does so for a
# reason -- a missing scene, a bad flag, a dead GPU -- and blind resubmission
# burns two GPUs re-reaching the same failure. The loop surfaces the reason;
# the fix and the resubmit are deliberate.
set -uo pipefail
cd "$(dirname "$0")"
OUTROOT=${OUTROOT:-/avl-west/runs/recheck-edit80}
POD=${POD:-horuan-nexussim}
EVERY=${EVERY:-300}

while :; do
  echo "===== $(date +%H:%M:%S) ====="
  kubectl get jobs -n cogrob -l app=navsafe-recheck80 \
    -o custom-columns=NAME:.metadata.name,SUCC:.status.succeeded,ACT:.status.active,FAIL:.status.failed \
    --no-headers 2>/dev/null

  kubectl exec -n cogrob "$POD" -- bash -c "
    done=\$(ls -d $OUTROOT/*/.done 2>/dev/null | wc -l)
    dirs=\$(ls -d $OUTROOT/*/ 2>/dev/null | grep -cv '/logs/\$')
    gifs=\$(ls $OUTROOT/*/visualization/combined.gif 2>/dev/null | wc -l)
    mp4s=\$(ls $OUTROOT/*/visualization/combined.mp4 2>/dev/null | wc -l)
    echo \"  scenarios: \$done done of 80, \$dirs started | combined.gif \$gifs, mp4 \$mp4s\"
    python3 /avl-west/navsafe_dev/gif2mp4.py $OUTROOT 2>&1 | tail -6
  " 2>/dev/null

  # Anything that failed, with the reason rather than the fact.
  for j in $(kubectl get jobs -n cogrob -l app=navsafe-recheck80 \
               -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    echo "  --- $j FAILED ---"
    p=$(kubectl get pods -n cogrob --no-headers 2>/dev/null | grep "^$j-" | tail -1 | awk '{print $1}')
    [ -n "$p" ] && kubectl logs -n cogrob "$p" -c sim --tail=25 2>/dev/null | sed 's/^/    /'
  done
  sleep "$EVERY"
done
