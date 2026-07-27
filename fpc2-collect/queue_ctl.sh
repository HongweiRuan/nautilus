#!/usr/bin/env bash
# Concurrency-limited queue for the fpc2 collection jobs on Nautilus.
# Keeps CONCURRENCY jobs in flight; re-applies queued manifests (longest-first)
# as running ones complete. suspend is blocked by the nrp util webhook, so we
# delete/re-create instead. Safe to re-run: it only applies a queued job when a
# slot is free and that job isn't already present.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
NS=cogrob
CONCURRENCY=4
# priority order to launch as slots free (longest sim-step jobs first; h10 last)
QUEUE="horuan-fpc2-h80-s2 horuan-fpc2-h80-s3 horuan-fpc2-h40-s0 horuan-fpc2-h40-s1 horuan-fpc2-h10-s0"
ALL="horuan-fpc2-h1-s0 horuan-fpc2-h20-s0 horuan-fpc2-h80-s0 horuan-fpc2-h80-s1 $QUEUE"

job_state() { # -> DONE | FAIL | ACTIVE | ABSENT
  local j=$1 s
  s=$(kubectl get job -n $NS "$j" -o jsonpath='{.status.succeeded}|{.status.failed}|{.status.active}' 2>/dev/null) || { echo ABSENT; return; }
  [ -z "$s" ] && { echo ABSENT; return; }
  case "$s" in
    1\|*) echo DONE ;;
    *\|1\|*) echo FAIL ;;
    *) echo ACTIVE ;;
  esac
}

for iter in $(seq 1 4000); do
  ts=$(date +%m-%d_%H:%M:%S)
  inflight=0; done=0; fail=""
  line=""
  for j in $ALL; do
    st=$(job_state "$j")
    case "$st" in
      DONE) done=$((done+1)) ;;
      FAIL) fail="$fail $j" ;;
      ACTIVE) inflight=$((inflight+1)) ;;
    esac
    line="$line ${j##horuan-fpc2-}:$st"
  done
  echo "[$ts] inflight=$inflight done=$done/9 fail=[$fail] |$line"
  [ -n "$fail" ] && echo "!! FAILED job(s):$fail -- leaving for inspection"
  [ "$done" -ge 9 ] && { echo "ALL_9_DONE"; break; }
  # launch next queued if we have a free slot
  if [ "$inflight" -lt "$CONCURRENCY" ]; then
    for q in $QUEUE; do
      st=$(job_state "$q")
      if [ "$st" = "ABSENT" ]; then
        echo "[$ts] free slot ($inflight/$CONCURRENCY) -> applying $q"
        kubectl apply -f "$DIR/$q.yaml" 2>&1 | sed 's/^/    /'
        break
      fi
    done
  fi
  sleep 300
done
