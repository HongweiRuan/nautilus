#!/bin/bash
# Six shards over the eighty edited scenarios, one Job each, two GPUs each.
#
# One at a time with retry: the Nautilus admission webhook refuses new GPU work
# when the account's existing pods are under-used, and a burst walks the whole
# list on one refusal and submits nothing.
set -uo pipefail
cd "$(dirname "$0")"

N=${N:-6}
OUTROOT=${OUTROOT:-/avl-west/runs/recheck-edit80}
REPLAY=${REPLAY:-20}
EVALF=${EVALF:-200}
BACKOFF=${BACKOFF:-300}
NS=cogrob

kubectl create configmap navsafe-recheck80-cfg -n "$NS" \
  --from-file=run_nre.sh --from-file=run_sim.sh \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null || exit 1
mkdir -p rendered

i=0
while [ "$i" -lt "$N" ]; do
  NAME="navsafe-recheck80-w$(printf %02d "$i")"
  f="rendered/$NAME.yaml"
  sed -e "s|__NAME__|$NAME|g" -e "s|__IDX__|$i|g" -e "s|__N__|$N|g" \
      -e "s|__OUTROOT__|$OUTROOT|g" \
      -e "s|__REPLAY__|$REPLAY|g" -e "s|__EVALF__|$EVALF|g" \
      templates/shard.yaml > "$f"
  kubectl delete job "$NAME" -n "$NS" --ignore-not-found >/dev/null 2>&1
  if out=$(kubectl apply -f "$f" 2>&1); then
    echo "[$(date +%H:%M:%S)] accepted $NAME"
    i=$((i+1)); sleep 20
  else
    case "$out" in
      *utilization*|*denied\ the\ request*)
        echo "[$(date +%H:%M:%S)] refused (utilisation policy); retrying $NAME in ${BACKOFF}s";
        sleep "$BACKOFF";;
      *) echo "[$(date +%H:%M:%S)] $NAME FAILED: $out"; exit 1;;
    esac
  fi
done
echo "--- $N shards submitted ($REPLAY replay + $EVALF eval frames, DrivoR, -> $OUTROOT) ---"
kubectl get jobs -n "$NS" -l app=navsafe-recheck80
