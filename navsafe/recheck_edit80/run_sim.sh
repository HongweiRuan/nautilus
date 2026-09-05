#!/bin/bash
# The eval half of one shard: closed-loop DrivoR over this shard's edited
# scenarios, rendered by the sibling container on 127.0.0.1.
#
# Everything the scenario needs comes from the fixed dataset layout
# (/avl-west/navsafe_eval/dataset/<token>/): the published Arrow, the four
# reconstructions, the per-sub-clip origin offsets, the manifest. The recipe
# comes from the repo and the actor library from /avl-west/nurec_assets, which
# is where the recipes' own absolute paths point.
#
# NOT `set -e`: a bootstrap step that fails unprotected turns into a silent
# death with a log that just stops. Failures are checked and reported instead.
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
REPO=${REPO:-/hugsim-storage/NexusSim}
OUTROOT=${OUTROOT:-/avl-west/runs/recheck-edit80}
CKPT=${CKPT:-/avl-west/navsafe_eval/model_zoo/drivor/drivor_Nav1_25epochs.pth}
REPLAY_FRAMES=${REPLAY_FRAMES:-20}
EVAL_FRAMES=${EVAL_FRAMES:-200}
PORT=${PORT:-8080}
WORKER_INDEX=${WORKER_INDEX:-0}; WORKERS=${WORKERS:-1}
say() { echo "[sim w$WORKER_INDEX $(date +%H:%M:%S)] $*"; }

# Tell the sibling renderer to stop when this container is done, however it
# ends. Without it `serve-grpc` runs forever, the pod never completes even
# though the eval exited 0, and the Job sits "active" holding two GPUs doing
# nothing -- which is exactly what all six shards did on 2026-09-03.
# TWO flags, and the second is on the PVC on purpose. The emptyDir one dies
# with the pod, so when the renderer failed to notice it on 2026-09-04 -- both
# jobs left `nre` running for five hours after `sim` exited 0, holding four
# GPUs -- there was nothing left to inspect and no way to tell whether the
# writer or the reader was at fault. The PVC copy survives the pod and is
# visible from outside it.
SENTINEL=${SENTINEL:-/sentinel/sim-done}
SENTINEL_PVC=${SENTINEL_PVC:-$OUTROOT/logs/sim-done-w${WORKER_INDEX}}
_flag() { rc=$?; mkdir -p "$(dirname "$SENTINEL")" "$(dirname "$SENTINEL_PVC")" 2>/dev/null
          echo "$rc" > "$SENTINEL" 2>/dev/null
          echo "$rc" > "$SENTINEL_PVC" 2>/dev/null; }
trap _flag EXIT

mkdir -p "$OUTROOT/logs"
# ONLY names the scenarios directly -- for a one-off over a handful of them,
# such as checking a re-calibrated asset. Without it this is shard
# WORKER_INDEX of the 80-way campaign. Same script either way: the bootstrap,
# the Kit cache, the scene-list check and the flags are what must not drift
# between a campaign run and a spot check.
if [ -n "${ONLY:-}" ]; then
  read -r -a MY <<< "$ONLY"
  say "explicit list: ${#MY[@]} scenarios"
else
  mapfile -t ALL < <(cd "$BENCH" && ls *.yaml | sed 's/\.yaml$//' | sort)
  MY=()
  for i in "${!ALL[@]}"; do
    [ $(( i % WORKERS )) -eq "$WORKER_INDEX" ] && MY+=("${ALL[$i]}")
  done
  say "shard: ${#MY[@]} of ${#ALL[@]} scenarios"
fi

# ── 1. environment ───────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
say "apt: GL/X libs the renderer client and IsaacSim need"
apt-get update -qq && apt-get install -y -qq git curl python3-venv python3-dev ffmpeg \
  libglu1-mesa libxt6 libgl1 libglx0 libegl1 libglib2.0-0 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxext6 libxrender1 libx11-6 libxfixes3 libxdamage1 libsm6 \
  libice6 libgomp1 >/dev/null || { say "FATAL: apt failed"; exit 1; }

export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
# Pod-local uv cache, as pods/horuan-nexussim.yaml has it. The 62 GB cache on
# /avl-west sits on a different filesystem from the venv, so uv cannot hardlink
# and copies all ~360 packages instead -- ~40 min a job rather than ~15.
export UV_CACHE_DIR=/root/.cache/uv
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES
VENV=/root/nexussim-venv
export UV_PROJECT_ENVIRONMENT=$VENV VIRTUAL_ENV=$VENV
for i in 1 2 3 4; do
  command -v uv >/dev/null && break
  python -m pip install --quiet --user uv 2>/dev/null \
    || curl -LsSf https://astral.sh/uv/install.sh | sh
  hash -r; sleep 10
done
command -v uv >/dev/null || { say "FATAL: uv unavailable"; exit 1; }
cd "$REPO"
if ! $VENV/bin/python -c "import isaacsim, isaaclab, nexussim" 2>/dev/null; then
  say "uv sync (IsaacSim 6.0 + cu128 torch, ~15 min)"
  uv sync --all-extras --python 3.12 || { say "FATAL: uv sync failed"; exit 1; }
  [ -d /root/IsaacLab/.git ] || git clone --depth 1 --branch v3.0.0-beta \
    https://github.com/isaac-sim/IsaacLab.git /root/IsaacLab
  for ext in isaaclab isaaclab_assets isaaclab_tasks isaaclab_rl isaaclab_mimic; do
    d=/root/IsaacLab/source/$ext
    [ -d "$d" ] && uv pip install --python $VENV/bin/python --no-deps -e "$d" >/dev/null
  done
  uv pip install --python $VENV/bin/python lazy_loader einops >/dev/null
fi
PY=$VENV/bin/python
"$PY" -c "import nexussim, isaaclab" || { say "FATAL: venv unusable"; exit 1; }
"$PY" -m pip install --quiet grpcio protobuf 2>&1 | tail -1

# ── 2. warm the Omniverse Kit shader/material cache ──────────────────────────
# The minutes before an eval evaluates anything are Kit compiling materials
# (omni.ujitso) and ray-tracing pipelines (RtPso) inside AppLauncher, on an
# EMPTY stage, into caches that die with the pod. Measured 2026-08-31:
# AppLauncher returned after 467 s cold and 10.5 s with these restored.
#
# Keyed on driver version -- the OptiX and Vulkan pipeline caches are. A miss
# only costs the compile, so nothing here aborts the job. To refresh after an
# IsaacSim upgrade or a driver change, run one eval to completion and repack:
#   KITPKG=$($PY -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))")
#   DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | tr -d ' ')
#   tar -cf /avl-west/navsafe_dev/kitcache/kitcache-3090-$DRV.tar -C "$KITPKG" kit \
#       -C / var/tmp/OptixCache_root root/.cache/ov root/.cache/warp root/.nv
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ')
KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$DRV.tar
if [ -f "$KITCACHE" ]; then
  KITPKG=$("$PY" -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))" 2>/dev/null)
  if [ -n "$KITPKG" ] && tar -xf "$KITCACHE" -C "$KITPKG" kit && tar -xf "$KITCACHE" -C / var root; then
    say "Kit shader cache restored (saves ~7.6 min of boot)"
  else
    say "Kit cache restore failed; IsaacSim will recompile (~8 min)"
  fi
else
  say "no Kit cache for driver $DRV; IsaacSim will recompile (~8 min)"
fi

# ── 3. wait for the sibling renderer, and CHECK ITS SCENE LIST ───────────────
NRELOG=$OUTROOT/logs/nre-w$WORKER_INDEX.log
say "waiting for serve-grpc"
for _ in $(seq 1 240); do
  grep -q "Serving on" "$NRELOG" 2>/dev/null && break
  sleep 10
done
grep -q "Serving on" "$NRELOG" 2>/dev/null || { say "FATAL: renderer never bound its port"; tail -40 "$NRELOG" 2>/dev/null; exit 1; }
SCENES=$(grep "Available scenes" "$NRELOG" | tail -1)
for TGT in "${MY[@]}"; do
  T=${TGT#*.}
  for i in 1 2 3 4; do
    echo "$SCENES" | grep -q "${T}s$i" || { say "FATAL: renderer is missing scene ${T}s$i"; exit 1; }
  done
done
for _ in $(seq 1 60); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3<&- 3>&-; break; }
  sleep 2
done
say "renderer up, all $(( ${#MY[@]} * 4 )) reconstructions present"

# ── 4. the rollout ───────────────────────────────────────────────────────────
export PYTHONPATH=$REPO:$REPO/third_party:$REPO/third_party/nurec_protos
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=$PORT NUREC_GRPC_TIMEOUT_S=600
export NUREC_GRPC_CAM_RIG=navsim
export PY123D_RECENTER=1 NEXUSSIM_NO_CAM_MAP_LINES=1
export NAVSAFE_WORK=/avl-west/navsafe_dev
# The actor library, from the same published release as the scenarios. A recipe
# names an asset by BASENAME and a gait bank by DIRECTORY name, and these two
# variables are what rebase its frozen absolute paths onto this copy; unset,
# the recipe's own paths are used verbatim. Rebasing does not disturb any
# checksum -- the digest pins the asset's CONTENT hash, not where it lives.
export NAVSAFE_ASSET_BANK=${NAVSAFE_ASSET_BANK:-/avl-west/navsafe_eval/asset}
export NAVSAFE_GAIT_BANK=${NAVSAFE_GAIT_BANK:-/avl-west/navsafe_eval/gait_bank}
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
export NEXUSSIM_NUREC_GPUS=1

ok=0; skip=0; fail=0; n=0
for TGT in "${MY[@]}"; do
  n=$((n+1)); T=${TGT#*.}; OUT=$OUTROOT/$TGT
  if [ -f "$OUT/.done" ]; then skip=$((skip+1)); say "[$n/${#MY[@]}] $TGT already done"; continue; fi

  # The hand-off says which of the four reconstructions owns each frame. It is
  # derived here rather than written into the Job because it carries absolute
  # paths, and rewritten onto the dataset's own offsets so the run reads one
  # tree rather than two.
  H=$("$PY" -m nexussim.navsafe handoff --token "$T" 2>/dev/null | tail -1)
  case "$H" in
    *NUREC_GRPC_HANDOFF*) ;;
    *) say "[$n/${#MY[@]}] $TGT FAILED: no hand-off"; fail=$((fail+1)); continue;;
  esac
  H=$(echo "$H" | sed -E "s#/avl-west/navsafe_5s_500/([0-9a-f]{16}s[1-4])/clips/[^,]*/nurec_origin_offset\.json#$DATASET/$T/offsets/\1.json#g")
  eval "$H"

  rm -rf "$OUT"; mkdir -p "$OUT"
  say "[$n/${#MY[@]}] $TGT: ${REPLAY_FRAMES} replay + ${EVAL_FRAMES} eval frames"
  "$PY" "$REPO/scripts/tools/eval_py123d.py" \
    --scenario-source py123d \
    --py123d-data-root "$DATASET/$T/arrow" --py123d-scene-index 0 \
    --nurec-work-dir "$DATASET" \
    --render-backend nurec_grpc --cam-height navsim \
    --model-type drivor --checkpoint "$CKPT" \
    --recipe "$BENCH/$TGT.yaml" \
    --traffic-mode navsafe \
    --ego-replay-frames "$REPLAY_FRAMES" --eval-frames "$EVAL_FRAMES" --eval-seed 1 \
    --terminate-on-collision \
    --execution-mode controller --controller lqr --replan-rate 5 \
    --camera-resolution-scale 1.0 \
    --enable-vis --vis-cameras CAM_L0,CAM_R0 \
    --nurec-cameras CAM_F0,CAM_L0,CAM_R0 \
    --log-level INFO --output-dir "$OUT" > "$OUTROOT/logs/$TGT.log" 2>&1
  rc=$?
  GOT=$(ls -1 "$OUT/frames" 2>/dev/null | wc -l)
  if [ "$GOT" -ge 1 ]; then
    touch "$OUT/.done"; ok=$((ok+1)); say "[$n/${#MY[@]}] $TGT OK ($GOT frames, rc=$rc)"
  else
    fail=$((fail+1)); say "[$n/${#MY[@]}] $TGT FAILED rc=$rc"
    tail -25 "$OUTROOT/logs/$TGT.log"
  fi
done
say "shard done: ok=$ok skip=$skip fail=$fail"
[ "$fail" -eq 0 ]
