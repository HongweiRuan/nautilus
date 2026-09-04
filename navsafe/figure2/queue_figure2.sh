#!/bin/bash
# Feed the sixteen in one at a time, riding out the Nautilus utilisation policy.
#
# `submit_figure2.sh` applies all sixteen in a burst, which is the right thing
# when the account has headroom and the wrong thing when it does not: the
# admission webhook refuses with "Your pods resources utilization is too low"
# and a burst walks the whole list on one refusal, submitting nothing. This
# submits one, checks whether it was accepted, and backs off when it was not.
#
# Nothing is ever deleted here. Freeing the account's own idle GPUs is a
# judgement call about other people's work, so it stays a human decision.
set -eo pipefail
cd "$(dirname "$0")"

OUTROOT=${OUTROOT:-/avl-west/runs/20260902-paper-figure2-drivor}
REPLAY=${REPLAY:-20}
EVALF=${EVALF:-180}
BACKOFF=${BACKOFF:-300}          # seconds to wait after a refusal
MAX_ACTIVE=${MAX_ACTIVE:-16}     # never hold more than this many of ours at once
NS=cogrob

TARGETS=()
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  TARGETS+=("$line")
done < scenarios.txt

kubectl create configmap navsafe-figure2-cfg -n "$NS" \
  --from-file=run_figure2_worker.sh --dry-run=client -o yaml | kubectl apply -f - >/dev/null
mkdir -p rendered

name_of() { echo "navsafe-fig2-$(echo "$1" | tr 'A-Z.' 'a-z-')"; }
n_active() { kubectl get jobs -n "$NS" -l app=navsafe-figure2 \
  -o jsonpath='{range .items[*]}{.status.active}{"\n"}{end}' 2>/dev/null | grep -c 1 || true; }

pending=("${TARGETS[@]}")
while [ "${#pending[@]}" -gt 0 ]; do
  T=${pending[0]}
  NAME=$(name_of "$T")
  if kubectl get job "$NAME" -n "$NS" >/dev/null 2>&1; then
    echo "[$(date +%H:%M:%S)] $NAME already submitted"
    pending=("${pending[@]:1}"); continue
  fi
  while [ "$(n_active)" -ge "$MAX_ACTIVE" ]; do
    echo "[$(date +%H:%M:%S)] $MAX_ACTIVE of ours already active; waiting"
    sleep "$BACKOFF"
  done
  f="rendered/$NAME.yaml"
  sed -e "s|__NAME__|$NAME|g" -e "s|__TARGET__|$T|g" \
      -e "s|__OUTROOT__|$OUTROOT|g" \
      -e "s|__REPLAY__|$REPLAY|g" -e "s|__EVALF__|$EVALF|g" \
      templates/figure2.yaml > "$f"
  if out=$(kubectl apply -f "$f" 2>&1); then
    echo "[$(date +%H:%M:%S)] accepted $NAME  (${#pending[@]} left including this)"
    pending=("${pending[@]:1}")
    sleep 20                      # let the scheduler place it before the next
  else
    case "$out" in
      *utilization*|*denied\ the\ request*)
        echo "[$(date +%H:%M:%S)] refused (utilisation policy); retrying $NAME in ${BACKOFF}s"
        sleep "$BACKOFF";;
      *)
        echo "[$(date +%H:%M:%S)] $NAME FAILED to apply: $out"
        pending=("${pending[@]:1}");;
    esac
  fi
done
echo "--- all ${#TARGETS[@]} submitted ---"
kubectl get jobs -n "$NS" -l app=navsafe-figure2
