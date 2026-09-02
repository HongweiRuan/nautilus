#!/usr/bin/env bash
# chain.sh — drive the whole pipeline unattended: ncore + arrow, then aux once ncore
# has drained, then train once aux has drained.
#
# Exists because the three GPU stages are strictly ordered and each takes hours, and
# because the Nautilus admission webhook is currently refusing every apply ("pods
# resources utilization is too low"). Both are just "wait and retry", which is not
# worth a human sitting on it.
#
#   ./chain.sh                 # foreground, logs to chain.log as well
#   nohup ./chain.sh &         # detached
#
# Safe to kill and restart at any point: submit_stage.sh is idempotent — it re-reads
# CephFS for what is built and the live jobs for what is owned, and submits only the gap.
set -uo pipefail
cd "$(dirname "$0")"

NS="${NS:-cogrob}"
APP=illegal_turn_recon
POLL="${POLL:-300}"                 # seconds between checks
GIVEUP_H="${GIVEUP_H:-24}"          # stop retrying a rejected submit after this long
LOG=chain.log

say() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# Submit a stage, retrying while the admission webhook refuses it.
submit() {
  local stage=$1 deadline=$(( $(date +%s) + GIVEUP_H * 3600 ))
  local try; try=$(mktemp)
  while :; do
    say "submitting $stage ..."
    # capture THIS attempt on its own: grepping the whole log would match the
    # rejection from a previous round forever and mask a real failure.
    if ./submit_stage.sh "$stage" >"$try" 2>&1; then
      cat "$try" >> "$LOG"; say "$stage submitted (or already complete)"
      rm -f "$try"; return 0
    fi
    cat "$try" >> "$LOG"
    if grep -q "utilization is too low" "$try" && [ "$(date +%s)" -lt "$deadline" ]; then
      say "$stage refused by the Nautilus utilization policy — retrying in ${POLL}s"
      sleep "$POLL"
      continue
    fi
    say "$stage FAILED for a reason that is not the utilization policy — see $LOG"
    rm -f "$try"; return 1
  done
}

# Block until no job of this stage still has a live pod.
drain() {
  local stage=$1
  while :; do
    local n
    n=$(kubectl get jobs -n "$NS" -l "app=$APP,stage=$stage" \
          -o jsonpath='{range .items[*]}{.status.active}{"\n"}{end}' 2>/dev/null \
        | grep -c '[1-9]')
    [ "${n:-0}" -eq 0 ] && { say "$stage drained"; return 0; }
    say "$stage: $n job(s) still active — checking again in ${POLL}s"
    sleep "$POLL"
  done
}

say "=== chain start ==="
submit ncore || exit 1
submit arrow || exit 1          # independent of ncore, so fire it straight away
drain  ncore
submit aux   || exit 1
drain  aux
submit train || exit 1
say "=== all stages submitted; train is running (~36 h per shard) ==="
say "watch: kubectl get pods -n $NS -l app=$APP,stage=train"
