#!/usr/bin/env bash
# Progress of the navsafe-eval sweep: counts Complete/Failed/Running/Pending
# across all submitted (model, seed) jobs.
#
#   ./status.sh                one-shot summary, all jobs
#   WATCH=1 ./status.sh        refresh every 30s until all terminal
#   ./status.sh failed         list failed job names
set -euo pipefail
NS=cogrob
SEL="app=navsafe-eval"

show() {
  local j; j=$(kubectl get jobs -n $NS -l "$SEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}|{.status.succeeded}|{.status.failed}|{.status.active}{"\n"}{end}' 2>/dev/null)
  local tot ok fail act
  tot=$(printf '%s\n' "$j" | grep -c '|' || true)
  ok=$(printf '%s\n'  "$j" | awk -F'|' '$2==1' | wc -l | tr -d ' ')
  fail=$(printf '%s\n' "$j" | awk -F'|' '$3!=""&&$3!=0&&$2!=1' | wc -l | tr -d ' ')
  act=$(printf '%s\n'  "$j" | awk -F'|' '$4!=""&&$4!=0&&$2!=1' | wc -l | tr -d ' ')
  local pend=$(( tot - ok - fail - act )); [ "$pend" -lt 0 ] && pend=0
  echo "[navsafe-eval] total=$tot  complete=$ok  running=$act  pending=$pend  failed=$fail"
  [ "$((ok+fail))" -ge "$tot" ] && [ "$tot" -gt 0 ] && return 9 || return 0
}

if [ "${1:-}" = "failed" ]; then
  kubectl get jobs -n $NS -l "$SEL" \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.failed}|{.status.succeeded}{"\n"}{end}' \
    | awk -F'[=|]' '$2!=""&&$2!=0&&$3!=1{print $1}'
  exit 0
fi

if [ -n "${WATCH:-}" ]; then
  while true; do show && sleep 30 || { echo "[navsafe-eval] all terminal"; break; }; done
else
  show || true
fi
