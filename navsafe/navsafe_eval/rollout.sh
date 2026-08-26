#!/usr/bin/env bash
# Restart the running fleet onto a changed models.tsv / run_worker.sh, ONE worker
# at a time.
#
# Why not `kubectl delete jobs -l app=navsafe-eval` then ./submit_eval.sh: that
# drops the account's GPU utilisation to zero, and the util-policy webhook then
# refuses every new Job for the next ~20 minutes (measured 2026-08-26 — it cost
# the fleet a 20 minute stall). Replacing workers one by one keeps utilisation
# roughly flat, so the webhook never sees an idle account.
#
# Workers read /cfg/models.tsv ONCE at start-up, so a ConfigMap edit alone does
# not reach a running pod; the pod has to be replaced. Cells already scored are
# skipped by the new pod, so a rollout costs one venv build (~4 min) per worker
# plus whatever cell was in flight.
#
#   WORKERS=25 ./rollout.sh
set -uo pipefail
cd "$(dirname "$0")"
NS=${NS:-cogrob}
WORKERS=${WORKERS:-25}
case "$WORKERS" in ''|*[!0-9]*) echo "!! WORKERS must be a positive integer"; exit 1;; esac

echo "=== adapter readiness ==="
./check_adapters.sh || { echo "!! not every row is runnable — not rolling"; exit 1; }

kubectl create configmap navsafe-eval-cfg -n "$NS" \
  --from-file=run_worker.sh=run_worker.sh \
  --from-file=models.tsv=models.tsv \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null || exit 1
echo "=== configmap navsafe-eval-cfg updated ==="

for i in $(seq 0 $((WORKERS-1))); do
  W=$(printf 'w%02d' "$i")
  [ -f "rendered/$W.yaml" ] || { echo "[$W] no rendered manifest — run submit_eval.sh first"; exit 1; }
  kubectl delete job -n "$NS" "navsafe-eval-$W" --wait=true >/dev/null 2>&1
  out=$(kubectl apply -f "rendered/$W.yaml" 2>&1)
  echo "[$W] $out"
  case "$out" in
    *created*|*configured*) ;;
    *"utilization is too low"*)
      echo "=== UTIL-POLICY DENIED at $W — stop here, let it expire, then re-run ==="; exit 2;;
    *) echo "    (unrecognised result — stopping)"; exit 3;;
  esac
done
echo "=== rolled $WORKERS workers ==="
./status.sh
