#!/bin/bash
# The renderer half of one shard. Its own GPU, its own container, same pod as
# the eval -- so the eval reaches it on 127.0.0.1 and neither has to know where
# the other landed.
#
# Only THIS shard's reconstructions are offered. `serve-grpc` scans the glob
# once at start-up and never again, so pointing five shards at all 134 dataset
# scenarios would make each of them walk 536 usdz over CephFS to serve 20.
set -uo pipefail

# The scenarios come from the local mirror of the PUBLISHED release,
# /avl-west/navsafe_dev/full_test_mirror/<token>/ -- the HF `full_test` layout,
# with the 2.1 GB usdz symlinked into the 877 GB download beside it.
#
# Not the corpus (/avl-west/navsafe_5s_500): its Arrow runs 16-20 frames past
# what the four reconstructions cover, and the frozen recipes are cut to the
# published window, so a recipe with inserted actors is refused there --
# `baked for T=200 frames but this host has 216`.
DATASET=${DATASET:-/avl-west/navsafe_dev/full_test_mirror}
SCENARIOS=${SCENARIOS:-/cfg/scenarios.txt}
PORT=${PORT:-8080}
OUTROOT=${OUTROOT:-/avl-west/runs/20260907-edit24-handoff8}
LOGDIR=$OUTROOT/logs; mkdir -p "$LOGDIR"
WORKER_INDEX=${WORKER_INDEX:-0}; WORKERS=${WORKERS:-1}
say() { echo "[nre w$WORKER_INDEX $(date +%H:%M:%S)] $*"; }

# ── which scenarios are mine ─────────────────────────────────────────────────
# Round-robin over the list, not over a glob of the recipe directory: this
# campaign evaluates 24 of the 80, and the list is the campaign's definition.
# ONLY overrides it for a one-off over a handful.
if [ -n "${ONLY:-}" ]; then
  read -r -a MY <<< "$ONLY"
  say "explicit list: ${#MY[@]} scenarios"
else
  mapfile -t ALL < <(grep -v '^[[:space:]]*#' "$SCENARIOS" | grep -v '^[[:space:]]*$')
  MY=()
  for i in "${!ALL[@]}"; do
    [ $(( i % WORKERS )) -eq "$WORKER_INDEX" ] && MY+=("${ALL[$i]}")
  done
  say "shard: ${#MY[@]} of ${#ALL[@]} scenarios"
fi

# ── a stale sentinel would stop this container before it started ─────────────
# The PVC sentinel outlives the pod on purpose (see run_sim.sh), which means a
# previous run of the same shard index leaves one behind. Clear ours here: the
# eval writes it only on its way out, minutes from now, so there is no race
# worth guarding beyond this.
SENTINEL=${SENTINEL:-/sentinel/sim-done}
SENTINEL_PVC=${SENTINEL_PVC:-$OUTROOT/logs/sim-done-w${WORKER_INDEX}}
rm -f "$SENTINEL" "$SENTINEL_PVC" 2>/dev/null

POOL=/root/pool; mkdir -p "$POOL"
n=0
for TGT in "${MY[@]}"; do
  T=${TGT#*.}
  for i in 1 2 3 4; do
    f="$DATASET/$T/${T}s$i.usdz"
    [ -e "$f" ] && { ln -sf "$f" "$POOL/${T}s$i.usdz"; n=$((n+1)); }
  done
done
say "artifact pool: $n reconstructions for ${#MY[@]} scenarios"
[ "$n" -eq $(( ${#MY[@]} * 4 )) ] || say "WARNING: expected $(( ${#MY[@]} * 4 )) usdz, linked $n"
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
while [ ! -f "$SENTINEL" ] && [ ! -f "$SENTINEL_PVC" ]; do
  kill -0 $SERVE_PID 2>/dev/null || { say "serve-grpc exited on its own"; wait $SERVE_PID; exit $?; }
  sleep 10
done
say "the eval is finished (rc=$(cat "$SENTINEL" 2>/dev/null)); stopping serve-grpc"
kill $SERVE_PID 2>/dev/null
wait $SERVE_PID 2>/dev/null
exit 0
