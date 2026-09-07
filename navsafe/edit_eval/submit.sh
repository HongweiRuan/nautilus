#!/bin/bash
# Five shards over the 24 scenarios, one Job each, two GPUs each.
#
# One at a time with retry: the Nautilus admission webhook refuses new GPU work
# when the account's existing pods are under-used, and a burst walks the whole
# list on one refusal and submits nothing. Transport errors are retried too --
# a network blip once killed this after two hours of waiting.
set -uo pipefail
cd "$(dirname "$0")"

N=${N:-5}
OUTROOT=${OUTROOT:-/avl-west/runs/20260907-edit24-handoff8}
REPLAY=${REPLAY:-8}
EVALF=${EVALF:-150}
BACKOFF=${BACKOFF:-300}
NS=${NS:-cogrob}

echo "--- preflight ---"
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "FATAL: no access to namespace $NS"; exit 1; }
for pvc in avl-west-vol horuan-hugsim-vol; do
  kubectl get pvc "$pvc" -n "$NS" >/dev/null 2>&1 || { echo "FATAL: PVC $pvc not visible in $NS"; exit 1; }
done
kubectl get secret ngc-pull -n "$NS" >/dev/null 2>&1 \
  || echo "WARNING: no ngc-pull secret in $NS -- the NGC image pull will fail"
n_scen=$(grep -vc '^[[:space:]]*#' scenarios.txt)
echo "  namespace $NS, PVCs present, $n_scen scenarios over $N shards"

kubectl create configmap navsafe-editeval-cfg -n "$NS" \
  --from-file=run_nre.sh --from-file=run_sim.sh --from-file=scenarios.txt \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null \
  || { echo "FATAL: could not write the configmap"; exit 1; }
mkdir -p rendered

i=0
while [ "$i" -lt "$N" ]; do
  NAME="navsafe-editeval-w$(printf %02d "$i")"
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
        echo "[$(date +%H:%M:%S)] refused (utilisation policy); retrying $NAME in ${BACKOFF}s"
        sleep "$BACKOFF";;
      *timeout*|*connection\ refused*|*openapi*|*EOF*|*TLS*|*i/o\ timeout*)
        echo "[$(date +%H:%M:%S)] transport error; retrying $NAME in 60s"
        sleep 60;;
      *) echo "[$(date +%H:%M:%S)] $NAME FAILED: $out"; exit 1;;
    esac
  fi
done
echo "--- $N shards submitted ($REPLAY replay + $EVALF eval frames, DrivoR, -> $OUTROOT) ---"
kubectl get jobs -n "$NS" -l app=navsafe-editeval
