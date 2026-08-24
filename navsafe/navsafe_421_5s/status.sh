#!/usr/bin/env bash
# Progress of one bulk stage: counts Complete / Failed / Running / Pending across
# all 421 jobs (selected by label app=navhard421-5s,stage=<stage>).
#
#   ./status.sh <stage>            one-shot summary
#   WATCH=1 ./status.sh <stage>    refresh every 30s until all terminal
#   ./status.sh <stage> failed     list the failed job names
set -euo pipefail
NS=cogrob
STAGE="${1:-}"
case "$STAGE" in ncore|arrow|aux|train|export|eval) ;; *)
  echo "usage: [WATCH=1] $0 <ncore|arrow|aux|train|export|eval> [failed]"; exit 1;; esac
SEL="app=navhard421-5s,stage=$STAGE"

show() {
  local j; j=$(kubectl get jobs -n $NS -l "$SEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}|{.status.succeeded}|{.status.failed}|{.status.active}{"\n"}{end}' 2>/dev/null)
  local tot ok fail act
  tot=$(printf '%s\n' "$j" | grep -c '|' || true)
  ok=$(printf '%s\n'  "$j" | awk -F'|' '$2==1' | wc -l | tr -d ' ')
  # "failed" only counts jobs that failed AND did NOT eventually succeed on
  # retry (backoffLimit>0) — else a retried-then-succeeded job double-counts.
  fail=$(printf '%s\n' "$j" | awk -F'|' '$3!=""&&$3!=0&&$2!=1' | wc -l | tr -d ' ')
  act=$(printf '%s\n'  "$j" | awk -F'|' '$4!=""&&$4!=0&&$2!=1' | wc -l | tr -d ' ')
  local pend=$(( tot - ok - fail - act )); [ "$pend" -lt 0 ] && pend=0
  echo "[$STAGE] total=$tot  complete=$ok  running=$act  pending=$pend  failed=$fail"
  [ "$((ok+fail))" -ge "$tot" ] && [ "$tot" -gt 0 ] && return 9 || return 0
}

if [ "${2:-}" = "failed" ]; then
  kubectl get jobs -n $NS -l "$SEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.failed}|{.status.succeeded}{"\n"}{end}' \
    | awk -F'[=|]' '$2!=""&&$2!=0&&$3!=1{print $1}'   # failed and NOT eventually succeeded
  exit 0
fi

if [ -n "${WATCH:-}" ]; then
  while true; do show && sleep 30 || { echo "[$STAGE] all terminal"; break; }; done
else
  show || true
fi
