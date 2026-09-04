#!/bin/bash
# The renderer half of one shard. Its own GPU, its own container, same pod as
# the eval -- so the eval reaches it on 127.0.0.1 and neither has to know where
# the other landed.
#
# Only THIS shard's reconstructions are offered. `serve-grpc` scans the glob
# once at start-up and never again, so pointing six shards at all 134 dataset
# scenarios would make each of them walk 536 usdz over CephFS to serve 56.
set -uo pipefail

BENCH=${BENCH:-/hugsim-storage/NexusSim/nexussim/navsafe/recipes/benchmark}
# The scenarios come from the local mirror of the PUBLISHED release,
# /avl-west/navsafe_dev/full_test_mirror/<token>/ -- the HF `full_test` layout,
# with the 2.1 GB usdz symlinked into the 877 GB download beside it. Verified
# 2026-09-03: all 80 resolve, and every Arrow's frame count AND timestamps match
# its recipe to the microsecond.
#
# Not the corpus (/avl-west/navsafe_5s_500): its Arrow runs 16-20 frames past
# what the four reconstructions cover, and the frozen recipes are cut to the
# published window, so a recipe with inserted actors is refused there --
# `baked for T=200 frames but this host has 216`.
DATASET=${DATASET:-/avl-west/navsafe_dev/full_test_mirror}
PORT=${PORT:-8080}
OUTROOT=${OUTROOT:-/avl-west/runs/recheck-edit80}
LOGDIR=$OUTROOT/logs; mkdir -p "$LOGDIR"
say() { echo "[nre w$WORKER_INDEX $(date +%H:%M:%S)] $*"; }

mapfile -t ALL < <(cd "$BENCH" && ls *.yaml | sed 's/\.yaml$//' | sort)
MY=()
for i in "${!ALL[@]}"; do
  [ $(( i % WORKERS )) -eq "$WORKER_INDEX" ] && MY+=("${ALL[$i]}")
done
say "shard: ${#MY[@]} of ${#ALL[@]} scenarios"

POOL=/root/pool; mkdir -p "$POOL"
n=0
for TGT in "${MY[@]}"; do
  T=${TGT#*.}
  for i in 1 2 3 4; do
    f="$DATASET/$T/${T}s$i.usdz"
    [ -e "$f" ] && { ln -sf "$f" "$POOL/${T}s$i.usdz"; n=$((n+1)); }
  done
done
say "artifact pool: $n reconstructions"
[ "$n" -gt 0 ] || { say "FATAL: empty pool"; exit 1; }

# --enable-editing-actors is what makes the edit_assets RPC available. Without
# it the insert is refused AFTER the PLY has loaded, so the episode renders an
# empty road while sim state still scores the actor -- a passing run with an
# invisible hazard, which is worse than a failure.
# The log goes to the PVC, not just to stdout: the eval runs in a SIBLING
# container and cannot read this one's stdout, and the one thing it must check
# before rendering anything is this server's scene list -- a renderer asked for
# a scene it does not hold falls back to raster silently.
say "starting serve-grpc on port $PORT (log: $LOGDIR/nre-w$WORKER_INDEX.log)"
/app/run serve-grpc --host 0.0.0.0 --port "$PORT" \
  --enable-editing-actors --renderer default --cache-size 4 \
  --artifact-glob "$POOL/*.usdz" 2>&1 | tee "$LOGDIR/nre-w$WORKER_INDEX.log" &
SERVE_PID=$!

# `serve-grpc` never returns, so this container has to be told when the shard
# is finished: the eval writes SENTINEL on its way out and this leaves with it.
# A Job pod completes only when EVERY container has exited -- without this the
# Job stays active on two GPUs after the eval is long done.
SENTINEL=${SENTINEL:-/sentinel/sim-done}
while [ ! -f "$SENTINEL" ]; do
  kill -0 $SERVE_PID 2>/dev/null || { say "serve-grpc exited on its own"; wait $SERVE_PID; exit $?; }
  sleep 10
done
say "the eval is finished (rc=$(cat "$SENTINEL" 2>/dev/null)); stopping serve-grpc"
kill $SERVE_PID 2>/dev/null
wait $SERVE_PID 2>/dev/null
exit 0
