#!/usr/bin/env bash
# One NavSafe eval worker: a renderer and a sequential eval loop over this
# worker's slice of the scenario set, inside one pod on two 3090s.
#
# Why it is shaped like this, since none of it is arbitrary:
#
#  * `run_bundle_eval.sh` cannot be used here. It starts the renderer with
#    `docker run` (the single-machine "Mode B" of docs/navsafe_eval.md); a pod
#    has no docker daemon. This is Mode A — a long-lived serve-grpc the eval
#    client reaches over the network — with server and client in the SAME pod, so
#    the network is loopback and the renderer cannot outlive the work. Every
#    eval FLAG below is copied from that wrapper verbatim, because the flags are
#    what make a score comparable and this file is not the place to have an
#    opinion about them.
#
#  * ONE renderer per worker, started once. serve-grpc costs 2-4 minutes to
#    publish its scenes and bind, and the eval venv costs ~15 minutes to build;
#    a pod that evaluated a single scenario would spend most of its life on
#    that. Here both are paid once and amortised over ~25 cells.
#
#  * Two GPUs, not one. serve-grpc with the harmonizer and --cache-size 4 was
#    measured at 21.8 GiB of a 3090's 23.6 GiB (see nexussim/nurec_serving/
#    serve-grpc.yaml), which leaves nothing for a policy. GPU 0 renders, GPU 1
#    runs the rollout.
#
#  * --cache-size 4 is a correctness floor, not a speed knob: a NavSafe scenario
#    is FOUR 5 s reconstructions the episode renders in turn, and at a smaller
#    cache they evict each other mid-episode.
#
#  * Token-outer, model-inner. All models run against one scenario before moving
#    to the next, so the renderer keeps that scenario's four reconstructions
#    resident across the whole model list instead of reloading ~8 GB per model.
#
#  * --eval-frames 600 states the episode bound instead of inheriting it.
#    `eval_frames` counts SCORED frames, so the run lasts
#    ego_replay_frames + eval_frames = 20 + 600 = 620 frames; leaving it unset
#    stops at ego_replay_frames + round(SAFETY_CEILING_S / sim_dt) =
#    20 + 60.0/0.1 = the same 620 (evaluator.py, "safety ceiling"). Same bound,
#    now written down — which is what keeps cells scored before this flag was
#    added comparable with the ones after.
#
#  * Resumable, per cell. A Job's pod is NOT time-capped here (verified: the
#    6 h activeDeadlineSeconds cogrob injects lands on bare Pods, not on pods a
#    Job owns), so a worker normally runs its slice to the end in one go. The
#    resume exists for the other reasons a pod dies — a node drain, an evicted
#    pod, a renderer that wedges — and it costs nothing when unused. A cell is
#    skipped when its log carries eval_py123d's DONE line AND a
#    navsafe_metrics.json exists — not on a frame count, which --enable-vis
#    being off makes zero for finished and unfinished runs alike.
#
# Inputs, all from the Job manifest:
#   WORKER_INDEX  this worker's index, 0-based
#   WORKERS       how many workers share the scenario set
#   SEEDS         space-separated --eval-seed values, e.g. "1" or "1 2 3"
#   NEXUSSIM_SHA  the commit every worker in the campaign evaluates
#   CAMPAIGN      output subtree name under outputs/
#
# Optional, for a campaign other than the model-zoo sweep:
#   ROOT          campaign root holding dataset/ and outputs/ (default below)
#   AH_REPLACE    1 = render the logged actors from their harvested assets
#                 (docs/navsafe_harvested_actors.md). The bank is found beside
#                 each scenario, so a bundle needs an `ah_assets` entry.
#   AH_REPLACE_MAX  how many resident copies at once -- a car served by three
#                 of the four 5 s scenes counts three times. 10 is what a 24 GB
#                 card holds through a whole episode with four reconstructions.
set -uo pipefail

: "${WORKER_INDEX:?}" "${WORKERS:?}" "${SEEDS:?}" "${NEXUSSIM_SHA:?}"
ROOT=${ROOT:-/avl-west/navsafe_eval}
DATASET=${DATASET:-$ROOT/dataset}
# Two campaigns can share one dataset and differ only in a flag -- a harvested
# replacement run and its baseline, for instance -- so the output subtree is
# separable from the root.
OUTROOT=${OUTROOT:-$ROOT/outputs}
MODELS_TSV=${MODELS_TSV:-/cfg/models.tsv}
ZOO=${ZOO:-$ROOT/model_zoo}
HARMONIZER_CACHE=${HARMONIZER_CACHE:-/avl-west/navsafe_dev/.harmonizer-cache}
PORT=8080
CELL_TIMEOUT=${CELL_TIMEOUT:-45m}
W=$(printf 'w%02d' "$WORKER_INDEX")

say() { echo "[$W $(date -u +%H:%M:%S)] $*"; }

# ── 0. which scenarios are mine ──────────────────────────────────────────────
# Deterministic stride, computed identically by every worker from the same
# sorted list, so no worker needs to be told and two workers never collide.
# Directories only, and only bundles that can actually be served. An entry under
# $DATASET that is not an evaluatable scenario killed a whole worker: it became a
# dangling symlink in the shard, serve-grpc died on FileNotFoundError before
# publishing any scene list, and the slice went down with it. Two produced that
# on 2026-08-26 — a stray top-level manifest.json (a FILE, which `ls` happily
# returns; since moved to ../dataset_manifest.json) and 442b2cf63c6f570a, which
# carries arrow/ and offsets/ but no usdz at all. Screened here, where the cost
# is one skipped scenario rather than one dead worker.
mapfile -t ALL_TOKENS < <(
  for d in "$DATASET"/*/; do
    t=$(basename "$d")
    [ -f "$d/manifest.json" ] && [ -d "$d/arrow" ] || continue
    # With replacement on, a scenario without a bank is not evaluatable in this
    # campaign at all: the eval refuses rather than quietly rendering the baked
    # actors, so screening here costs one scenario instead of one dead worker.
    [ "${AH_REPLACE:-0}" = "1" ] && { [ -f "$d/ah_assets/replace_manifest.json" ] || continue; }
    n=0; for f in "$d"/*.usdz; do [ -e "$f" ] && n=$((n+1)); done
    [ "$n" -ge 1 ] && echo "$t"
  done | sort
)
MY_TOKENS=()
for i in "${!ALL_TOKENS[@]}"; do
  [ $(( i % WORKERS )) -eq "$WORKER_INDEX" ] && MY_TOKENS+=("${ALL_TOKENS[$i]}")
done
say "scenarios ${#ALL_TOKENS[@]} evaluatable, ${#MY_TOKENS[@]} mine: ${MY_TOKENS[*]}"
[ ${#MY_TOKENS[@]} -gt 0 ] || { say "nothing to do"; exit 0; }

mapfile -t ROWS < <(grep -v '^\s*#' "$MODELS_TSV" | grep -v '^\s*$')
say "models: $(printf '%s ' "${ROWS[@]%% *}")"

# ── 1. environment ───────────────────────────────────────────────────────────
# The venv is built here, on the pod's own ephemeral /root, every time. It is
# NOT cached on the PVC: a shared interpreter tree on CephFS is not ours to
# create. ~15 minutes, paid once per pod.
export DEBIAN_FRONTEND=noninteractive
say "apt: GL/X libs the renderer and IsaacSim need"
# python3-dev is not decoration: SparseDriveV2 JIT-builds a C++/CUDA extension,
# `uv sync --python 3.12` resolves to this image's SYSTEM python (Ubuntu 24.04
# ships 3.12.3), and torch hands the compiler `-isystem /usr/include/python3.12`.
# Without the headers the C++ half of the build dies on `Python.h: No such file
# or directory` while the CUDA half compiles fine — which reads as a broken
# adapter rather than a missing apt package.
apt-get update -qq && apt-get install -y -qq git curl python3-venv python3-dev \
  libglu1-mesa libxt6 libgl1 libglx0 libegl1 libglib2.0-0 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxext6 libxrender1 libx11-6 libxfixes3 libxdamage1 libsm6 \
  libice6 libgomp1 >/dev/null || { say "apt FAILED"; exit 1; }

export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
export UV_CACHE_DIR=/root/.cache/uv UV_PROJECT_ENVIRONMENT=/root/nexussim-venv
for i in 1 2 3 4; do
  command -v uv >/dev/null && break
  python -m pip install --quiet --user uv 2>/dev/null \
    || pip install --quiet --user uv 2>/dev/null \
    || curl -LsSf https://astral.sh/uv/install.sh | sh
  hash -r; sleep 5
done
command -v uv >/dev/null || { say "uv unavailable"; exit 1; }

# Pinned checkout, cloned locally: 30 workers importing .py straight off CephFS
# would contend on __pycache__ writes, and a campaign has to be able to say
# which commit produced its numbers.
REPO=/root/ns
rm -rf "$REPO"
git clone --quiet --no-hardlinks /hugsim-storage/NexusSim "$REPO" || { say "clone FAILED"; exit 1; }
git -C "$REPO" checkout --quiet "$NEXUSSIM_SHA" || { say "checkout $NEXUSSIM_SHA FAILED"; exit 1; }
say "code at $(git -C "$REPO" log --oneline -1)"

# A clone carries COMMITTED state only, which is the point: a campaign has to be
# able to name the commit its numbers came from. But a feature under test is
# not committed yet, and without this the workers run code that does not have
# the flag and every cell dies on "unrecognized arguments".
#
# NEXUSSIM_OVERLAY=1 copies the source checkout's uncommitted changes on top and
# SAYS SO. Provenance does not silently degrade: eval_py123d already stamps a
# run from a dirty tree as corresponding to no commit and records the diff.
if [ "${NEXUSSIM_OVERLAY:-0}" = "1" ]; then
  SRC=/hugsim-storage/NexusSim
  # -uall lists untracked FILES; the default collapses them to a directory
  # ("?? nexussim/navsafe/harvest/"), which the -f test below then skips — that
  # is how a whole new package went missing and every cell died on an import.
  mapfile -t DIRTY < <(git -C "$SRC" status --porcelain -uall | awk '{print $NF}')
  for f in "${DIRTY[@]}"; do
    [ -f "$SRC/$f" ] || continue
    mkdir -p "$REPO/$(dirname "$f")" && cp -f "$SRC/$f" "$REPO/$f"
  done
  say "OVERLAID ${#DIRTY[@]} uncommitted file(s) from $SRC — these numbers "\
      "correspond to no commit"
  # Fail here rather than 25 minutes into the first cell. The overlay exists
  # solely so this worker can run code that is not committed yet; if the pieces
  # that code needs did not arrive, every cell dies identically on an import or
  # an unrecognized argument, and the fleet burns an hour saying so.
  if [ "${AH_REPLACE:-0}" = "1" ]; then
    grep -q -- "--asset-harvester-replace" "$REPO/scripts/tools/eval_py123d.py" \
      || { say "overlay incomplete: eval_py123d.py has no --asset-harvester-replace"; exit 1; }
    [ -f "$REPO/nexussim/navsafe/harvest/manifest.py" ] \
      || { say "overlay incomplete: nexussim/navsafe/harvest/ did not arrive"; exit 1; }
  fi
fi

cd "$REPO"
if ! /root/nexussim-venv/bin/python -c "import isaacsim, isaaclab, nexussim" 2>/dev/null; then
  say "uv sync (IsaacSim 6.0 + cu128 torch, ~15 min)"
  uv sync --all-extras --python 3.12 || { say "uv sync FAILED"; exit 1; }
  [ -d /root/IsaacLab/.git ] || git clone --depth 1 --branch v3.0.0-beta \
    https://github.com/isaac-sim/IsaacLab.git /root/IsaacLab
  for ext in isaaclab isaaclab_assets isaaclab_tasks isaaclab_rl isaaclab_mimic; do
    d=/root/IsaacLab/source/$ext
    [ -d "$d" ] && uv pip install --python /root/nexussim-venv/bin/python --no-deps -e "$d" >/dev/null
  done
  uv pip install --python /root/nexussim-venv/bin/python lazy_loader einops >/dev/null
  # SparseDriveV2 JIT-builds a CUDA extension (deformable attention) at its first
  # forward pass, and torch.utils.cpp_extension refuses to without ninja:
  # "Ninja is required to load C++ extensions". The NRE image ships nvcc 12.8 and
  # g++ but not ninja, so the cell died at frame 0 with an infra_failure that
  # reads like a broken adapter. Compiled once per pod into
  # /root/.cache/torch_extensions.
  uv pip install --python /root/nexussim-venv/bin/python ninja >/dev/null
fi
PY=/root/nexussim-venv/bin/python
"$PY" -c "import nexussim, isaaclab" || { say "venv unusable"; exit 1; }

# ── warm Omniverse Kit shader/material cache ─────────────────────────────────
# Without this every worker spends ~7.7 min inside AppLauncher, on an EMPTY
# stage, while Kit compiles materials (omni.ujitso) and ray-tracing pipelines
# (RtPso) into caches that die with the pod. Measured 2026-08-31 on an
# otherwise identical pair of jobs: AppLauncher returned after 467 s cold and
# 10.5 s restored, with byte-identical metrics. Ten workers per wave, so this
# is ~77 GPU-minutes a wave.
#
# The compile finishes before the scenario is read, so ONE cache serves every
# token. The tar is keyed on driver version (the OptiX and Vulkan pipeline
# caches are) and its members are venv-agnostic: `kit/` unpacks into whichever
# isaacsim package $PY has. A miss only costs the old boot time, so nothing
# here aborts. To refresh after an IsaacSim or driver upgrade, run one eval to
# completion and repack from that pod:
#   KITPKG=$("$PY" -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))")
#   tar -cf /avl-west/navsafe_dev/kitcache/kitcache-3090-$DRV.tar -C "$KITPKG" kit \
#       -C / var/tmp/OptixCache_root root/.cache/ov root/.cache/warp root/.nv
KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | tr -d ' ').tar
if [ -f "$KITCACHE" ]; then
  KITPKG=$("$PY" -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))" 2>/dev/null)
  if [ -n "$KITPKG" ] && tar -xf "$KITCACHE" -C "$KITPKG" kit && tar -xf "$KITCACHE" -C / var root; then
    say "Kit shader cache restored into $KITPKG"
  else
    say "Kit cache restore failed; IsaacSim will recompile (~8 min)"
  fi
else
  say "no Kit cache for this driver; IsaacSim will recompile (~8 min)"
fi
# `uv sync` rewrites uv.lock in place — it normalises the environment markers for
# this platform, same package versions — and every eval then records itself as
# "launched from a DIRTY tree ... this run corresponds to no commit". Restoring
# the file is what lets run_meta.json name the commit these numbers came from;
# the installed set is the locked one either way, which is why this is safe.
git -C "$REPO" checkout -- uv.lock 2>/dev/null || true

# The venv's bin/ has to be on PATH, not just its interpreter. torch checks for
# ninja by SHELLING OUT (`subprocess.run(["ninja", "--version"])` in
# verify_ninja_availability), so installing ninja into the venv while invoking
# only /root/nexussim-venv/bin/python leaves it invisible and SparseDriveV2 still dies
# at frame 0 with "Ninja is required to load C++ extensions". Checked here
# rather than trusted: the install is quiet, and its failure would otherwise
# surface 30 pods later as one adapter that never scores anything.
export PATH=/root/nexussim-venv/bin:$PATH
command -v ninja >/dev/null || { say "ninja not on PATH — sparsedrivev2 cannot JIT its CUDA extension"; exit 1; }
# The exact path torch will pass as -isystem, asked of the interpreter that will
# do the building rather than assumed from the apt package name.
INC=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
[ -f "$INC/Python.h" ] || { say "no Python.h under $INC — sparsedrivev2's extension cannot build"; exit 1; }
say "venv ready ($(git -C "$REPO" status --porcelain | wc -l) tracked files modified, ninja $(ninja --version), headers $INC)"

# ── 2. the renderer ──────────────────────────────────────────────────────────
# Its --artifact-glob covers only THIS worker's scenarios. serve-grpc scans the
# glob at start-up and reads every artifact it finds; pointing all 30 workers at
# all 508 reconstructions would make each of them scan half a terabyte of CephFS
# to serve twenty scenes.
SHARD=/root/shard
mkdir -p "$SHARD"
MY_SCENES=()
for T in "${MY_TOKENS[@]}"; do
  for f in "$DATASET/$T"/*.usdz; do
    [ -e "$f" ] || continue                     # a dangling link is not a scene
    b=$(basename "$f"); ln -sf "$f" "$SHARD/$b"; MY_SCENES+=("${b%.usdz}")
  done
done
mkdir -p "$HARMONIZER_CACHE"

SERVE_PID=""
start_serve() {
  say "serve-grpc starting on GPU 0"
  CUDA_VISIBLE_DEVICES=0 /app/run serve-grpc --host 0.0.0.0 \
    --enable-editing-actors --renderer default --cache-size 4 \
    --enable-harmonizer --harmonizer-cache "$HARMONIZER_CACHE" \
    --artifact-glob "$SHARD/*.usdz" > /tmp/serve.log 2>&1 &
  SERVE_PID=$!

  # The scene list is CHECKED, never assumed: a renderer asked for a scene it
  # does not hold falls back to raster silently, and the result reads as a
  # reconstruction-quality problem rather than a configuration one.
  for _ in $(seq 1 120); do
    kill -0 $SERVE_PID 2>/dev/null || { say "serve exited early"; tail -40 /tmp/serve.log; return 1; }
    grep -q "Available scenes" /tmp/serve.log && break
    sleep 5
  done
  local scenes; scenes=$(grep "Available scenes" /tmp/serve.log | tail -1)
  [ -n "$scenes" ] || { say "no scene list published"; tail -40 /tmp/serve.log; return 1; }
  for SC in "${MY_SCENES[@]}"; do
    echo "$scenes" | grep -q "$SC" || { say "MISSING scene $SC — would render raster"; return 1; }
  done
  # The scene list is not readiness: serve-grpc prints it while still loading
  # the harmonizer weights and binds the port ~2 min later. Connecting in that
  # gap dies with UNAVAILABLE from inside renderer setup.
  for _ in $(seq 1 120); do grep -q "Serving on" /tmp/serve.log && break; sleep 5; done
  grep -q "Serving on" /tmp/serve.log || { say "never bound its port"; tail -40 /tmp/serve.log; return 1; }
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3<&- 3>&-; break; }
    sleep 2
  done
  say "renderer accepting connections ($(echo "$scenes" | wc -w) scene tokens)"
}

serve_alive() {
  [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null || return 1
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3<&- 3>&-; return 0; }
  return 1
}

trap 'say "exiting"; tail -40 /tmp/serve.log 2>/dev/null; kill $SERVE_PID 2>/dev/null' EXIT
start_serve || exit 1

# ── 3. the sweep ─────────────────────────────────────────────────────────────
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=$PORT
# recon, not navsim: the reconstruction's own training camera, which is what
# nurec_grpc.py already defaults to. The navsim rig rebuilds a zero-distortion
# pinhole from seven scalars and renders rays the recon was never fit on.
# Set NUREC_GRPC_CAM_RIG=navsim to get the old behaviour back.
export NUREC_GRPC_CAM_RIG=${NUREC_GRPC_CAM_RIG:-recon} NUREC_GRPC_TIMEOUT_S=600
export PY123D_RECENTER=1
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NEXUSSIM_NO_CAM_MAP_LINES=1
export PYTHONPATH="$REPO:$REPO/third_party/nurec_protos"
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES UV_NO_SYNC=1
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
export CUDA_VISIBLE_DEVICES=1 NEXUSSIM_NUREC_GPUS=1

# Harvested-actor replacement, off unless the campaign asks for it. The flag
# takes no value: it finds <bundle>/ah_assets/replace_manifest.json beside the
# scenario's arrow. The cap is a VRAM budget, not a preference — all of a
# scenario's assets fit statically on a 24 GB card and then kill the episode
# partway through (measured: frame 151 of 200).
AH_FLAGS=()
if [ "${AH_REPLACE:-0}" = "1" ]; then
  AH_FLAGS=(--asset-harvester-replace)
fi
export NUREC_GRPC_ASSET_REPLACE_MAX=${AH_REPLACE_MAX:-10}
[ ${#AH_FLAGS[@]} -gt 0 ] && \
  say "harvested-actor replacement ON (max ${NUREC_GRPC_ASSET_REPLACE_MAX} resident copies)"

# VIS=1 writes per-frame BEV + front-camera images under <out>/frames/NNNNN/.
# Off by default: it is ~40% more wall-clock per cell and the scored numbers do
# not need it. On for runs whose product is a video rather than a metric.
VIS_FLAGS=()
if [ "${VIS:-0}" = "1" ]; then
  VIS_FLAGS=(--enable-vis)
  say "per-frame visualisation ON"
fi

# AH_PAIR=1 runs BOTH conditions for every cell, back to back on the same GPU
# against the same renderer process. That is the point: a side-by-side video of
# replaced vs not must differ in the replacement and nothing else — not the
# node, not the driver, not the server's warm state. The renderer resets its
# per-scene edit state at every setup, so the un-replaced half really is
# un-replaced even though a replaced episode ran on that server a minute ago.
if [ "${AH_PAIR:-0}" = "1" ]; then
  CONDS=(base ah)
  say "paired run: each cell evaluated twice, without and with replacement"
else
  CONDS=(single)
fi

done_n=0; skip_n=0; fail_n=0; consec_fail=0

# A pod whose GPU has gone bad fails every remaining cell in ~10 s and then
# exits 0, which tells the Job it SUCCEEDED and abandons the rest of the slice
# silently. That is what happened on ry-gpu-06 on 2026-08-26: its driver went
# bad at ~00:10, every eval started after that died in torch._C._cuda_init with
# "CUDA driver initialization failed, you might not have a CUDA gpu", and two
# workers reported themselves complete having scored 6 cells of 30. So: when the
# environment is what failed, exit NON-ZERO, and let the Job put the slice on a
# fresh pod — probably a different node.
gpu_is_gone() {
  grep -qE "cudaErrorInitializationError|CUDA driver initialization failed|no CUDA-capable device" "$1"
}
for T in "${MY_TOKENS[@]}"; do
  B="$DATASET/$T"
  HANDOFF=$("$PY" -m nexussim.navsafe.eval.bundle --handoff "$B" 2>/dev/null)
  [ -n "$HANDOFF" ] || { say "$T: no handoff, skipping scenario"; fail_n=$((fail_n+1)); continue; }
  export NUREC_GRPC_HANDOFF="$HANDOFF"

  for ROW in "${ROWS[@]}"; do
    set -- $ROW; SLUG=$1; MT=$2; CK=$3
    [ "$CK" = "none" ] && CKPT=none || CKPT="$ZOO/$CK"

    for SEED in $SEEDS; do
     for COND in "${CONDS[@]}"; do
      case "$COND" in
        base) CFLAGS=();               ODIR="$OUTROOT/baseline" ;;
        ah)   CFLAGS=(--asset-harvester-replace); ODIR="$OUTROOT/replaced" ;;
        *)    CFLAGS=("${AH_FLAGS[@]}"); ODIR="$OUTROOT" ;;
      esac
      OUT="$ODIR/$SLUG/seed$SEED/$T"
      LOG="$ODIR/$SLUG/seed$SEED/$T.log"
      if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && [ -f "$OUT/navsafe_metrics.json" ]; then
        skip_n=$((skip_n+1)); continue
      fi
      serve_alive || { say "renderer died — restarting"; kill $SERVE_PID 2>/dev/null; start_serve || exit 1; }

      mkdir -p "$OUT"
      say "$SLUG seed$SEED $T [$COND]"
      timeout --signal=KILL "$CELL_TIMEOUT" \
        "$PY" "$REPO/scripts/tools/eval_py123d.py" \
          --scenario-source py123d --py123d-data-root "$B/arrow" --py123d-scene-index 0 \
          --render-backend nurec_grpc --cam-height navsim \
          --model-type "$MT" --checkpoint "$CKPT" \
          --traffic-mode semi_reactive \
          --ego-replay-frames 20 \
          --terminate-on-collision \
          --controller lqr --execution-mode controller \
          --replan-rate 5 --camera-resolution-scale 1.0 \
          --eval-frames 600 \
          --eval-seed "$SEED" \
          --navsafe-prune-artifacts \
          "${CFLAGS[@]}" "${VIS_FLAGS[@]}" \
          --output-dir "$OUT" > "$LOG" 2>&1
      # One bad cell must not abandon the sweep; its reason is in its own log.
      if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && [ -f "$OUT/navsafe_metrics.json" ]; then
        done_n=$((done_n+1)); consec_fail=0; say "  OK"
      else
        fail_n=$((fail_n+1)); consec_fail=$((consec_fail+1)); say "  FAILED (see $LOG)"
        tail -5 /tmp/serve.log > "$ODIR/$SLUG/seed$SEED/$T.serve.log" 2>/dev/null
        if gpu_is_gone "$LOG"; then
          say "GPU UNUSABLE on $(hostname) — CUDA would not initialise. Failing so the Job reschedules."
          exit 1
        fi
        # More consecutive failures than one scenario has models: whatever is
        # wrong is not this scenario. Bail rather than burn the slice.
        if [ "$consec_fail" -ge 7 ]; then
          say "ABORT: $consec_fail consecutive failures across more than one scenario"
          exit 1
        fi
      fi
     done
    done
  done
done

say "WORKER DONE ok=$done_n skipped=$skip_n failed=$fail_n"
# A worker that finished its slice exits 0 even with failed cells: the Job must
# not retry a whole 6 h pod because one scenario is broken. status.sh is what
# reports the holes.
exit 0
