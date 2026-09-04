#!/bin/bash
# One shard of the fidelity render campaign: run the REAL eval, pure ego
# replay, and keep the camera frames.
#
# Why not `nre render` / `render-grpc`: both walk the reconstruction's training
# trajectory. What we need to characterise is what the EVAL renders -- its own
# pose chain, its recon rig, its harmonizer setting. Measured 2026-09-01, an eval frame and a render-grpc frame of the
# same clip are 30-37 dB apart after alignment, so the two are not
# interchangeable and the published FID/FVD/FDpi^k came from the wrong one.
#
# Two passes over the same shard, harmonizer OFF then ON, one serve-grpc each
# on GPU 0 while the eval runs on GPU 1. Nothing else differs between them.
#
# Env: WORKER_INDEX, WORKERS, OUTROOT, SCENARIOS (file of sids), STEPDIR.
# `set -uo pipefail`, NOT -e -- the same as navsafe_eval/run_worker_current.sh.
# Under -e any unguarded failure kills the shell with no message, and three
# separate silent deaths were chased through this bootstrap before that was
# the answer each time. Every failure that should stop the worker says so
# and exits explicitly; the ERR trap below reports the rest without
# aborting.
set -uo pipefail

CORPUS=${CORPUS:-/avl-west/navsafe_5s_500}
OUTROOT=${OUTROOT:-/avl-west/fidelity_eval/evalrender}
SCENARIOS=${SCENARIOS:-$OUTROOT/scenarios.txt}
STEPDIR=${STEPDIR:-$OUTROOT/steps}
HARMONIZER_CACHE=${HARMONIZER_CACHE:-/avl-west/navsafe_dev/.harmonizer-cache}
PORT=8080

say() { echo "[w$(printf %02d "$WORKER_INDEX") $(date +%H:%M:%S)] $*"; }
# Three separate silent exits have been chased through this bootstrap: a
# variable deleted by an over-broad edit, a tar option in the wrong place,
# and a command substitution with its stderr sent to /dev/null. Each left a
# log that simply stopped. `set -e` kills the shell without saying why, so
# say why.
set -E
trap 'rc=$?; say "FAILED rc=$rc at line $LINENO: $BASH_COMMAND"' ERR

mapfile -t ALL < "$SCENARIOS"
MY=()
for i in "${!ALL[@]}"; do
  [ $(( i % WORKERS )) -eq "$WORKER_INDEX" ] && MY+=("${ALL[$i]}")
done
say "shard: ${#MY[@]} of ${#ALL[@]} scenarios"

# ── 0. environment ───────────────────────────────────────────────────────────
# Mirrors run_worker_current.sh §1. Duplicated rather than shared because that
# script is mid-campaign (navsafe-final18) and factoring its preamble out would
# mean editing a live worker; fold the two together once that campaign ends.
#
export DEBIAN_FRONTEND=noninteractive
say "apt: GL/X libs the renderer and IsaacSim need"
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

SRC=${SRC:-/hugsim-storage/NexusSim}
REPO=/root/ns
# `git clone`, like run_worker_current.sh, not a copy of the working tree: a
# clone carries only tracked files, so the 15 GB in-tree .venv never enters the
# pod, and the campaign can name the commit its numbers came from.
NEXUSSIM_SHA=${NEXUSSIM_SHA:-$(git -C "$SRC" rev-parse HEAD)}
rm -rf "$REPO"
git clone --quiet --no-hardlinks "$SRC" "$REPO" || { say "clone FAILED"; exit 1; }
git -C "$REPO" checkout --quiet "$NEXUSSIM_SHA" || { say "checkout $NEXUSSIM_SHA FAILED"; exit 1; }
say "code at $(git -C "$REPO" log --oneline -1)"
grep -q "NUREC_GRPC_RENDER_STEPS" "$REPO/nexussim/render/nurec_grpc.py" \
  || { say "$NEXUSSIM_SHA has no NUREC_GRPC_RENDER_STEPS — wrong commit"; exit 1; }
# The actor-z fix (bbd27ad1). Before it every non-ego car rendered ~0.35 m
# high, which is the whole reason this campaign is being re-run; a shard that
# quietly picked up an older commit would put defective frames in the same
# tree as good ones and there is no way to tell them apart afterwards.
if grep -qF "pos[2] = 0.0" "$REPO/nexussim/env/nexussim_env.py"; then
  say "$NEXUSSIM_SHA still clamps actor z — pre-bbd27ad1 commit"; exit 1
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
  # Kept even though this campaign only loads DrivoR: torch looks for ninja
  # by shelling out, and its absence surfaces as a frame-0 infra_failure.
  uv pip install --python /root/nexussim-venv/bin/python ninja >/dev/null
fi
PY=/root/nexussim-venv/bin/python
# Announced before it runs: `import isaaclab` is the slowest thing in the
# bootstrap, and a pod killed inside it leaves a log that simply stops,
# with no line saying which step it stopped on.
say "checking the venv (import nexussim, isaaclab)"
"$PY" -c "import nexussim, isaaclab" || { say "venv unusable"; exit 1; }

# Before the Kit cache, because locating it is the FIRST `import isaacsim` in
# this script and that import blocks on an interactive EULA prompt without
# these. Set further down, the lookup exited non-zero, the cache was skipped
# with "cannot locate the isaacsim package", and every pod paid the ~8 min
# recompile the cache exists to avoid.
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES

# Warm Kit shader cache: without it every eval spends ~7.7 min inside
# AppLauncher compiling materials and RT pipelines that die with the pod.
KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ').tar
if [ -f "$KITCACHE" ]; then
  KITPKG=$("$PY" -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))") \
    || { say "cannot locate the isaacsim package; skipping the Kit cache"; KITPKG=""; }
  if [ -n "$KITPKG" ] && tar -xf "$KITCACHE" -C "$KITPKG" kit && tar -xf "$KITCACHE" -C / var root; then
    say "Kit shader cache restored"
  else
    say "Kit cache restore failed; IsaacSim will recompile (~8 min)"
  fi
else
  say "no Kit cache for this driver; IsaacSim will recompile (~8 min)"
fi
export PATH=/root/nexussim-venv/bin:$PATH
say "venv ready"

# ── the renderer's artifact pool ─────────────────────────────────────────────
# Only THIS shard's reconstructions. serve-grpc reads every artifact the glob
# finds at start-up; pointing four workers at all 1632 usdz would make each of
# them scan the whole corpus over CephFS to serve a hundred scenes.
SHARD=/root/shard; mkdir -p "$SHARD"
MY_SCENES=()
for T in "${MY[@]}"; do
  for f in "$CORPUS/$T"s?/output_5cam/*/artifacts/last.usdz; do
    [ -e "$f" ] || continue
    b=$(basename "$(dirname "$(dirname "$f")")")     # <sid>sN
    ln -sf "$f" "$SHARD/$b.usdz"; MY_SCENES+=("$b")
  done
done
say "artifact pool: ${#MY_SCENES[@]} reconstructions"
[ "${#MY_SCENES[@]}" -gt 0 ] || { say "empty pool"; exit 1; }
mkdir -p "$HARMONIZER_CACHE"

SERVE_PID=""
SERVE_PAT="serve-grpc --host"   # matches the wrapper AND the binary it launches
start_serve() {                      # $1 = on|off
  # --cache-size 1 with the harmonizer, 4 without. The harmonizer's weights sit
  # on the same GPU as the scene cache, and four resident scenes alongside them
  # take serve-grpc to ~18 GiB of a 3090's 23.5 -- a render then dies with
  # RESOURCE_EXHAUSTED partway through the pass, not at start-up.
  local harm=() cache=4
  if [ "$1" = on ]; then
    harm=(--enable-harmonizer --harmonizer-cache "$HARMONIZER_CACHE"); cache=1
  fi
  # A leftover from the previous pass owns the memory this one needs, so clear
  # it before starting rather than discovering it as an OOM 40 cells in.
  if pgrep -f "$SERVE_PAT" >/dev/null; then
    say "a serve-grpc is already running; stopping it before starting the $1 pass"
    kill_servers
  fi
  say "serve-grpc starting on GPU 0 (harmonizer=$1, cache-size=$cache)"
  CUDA_VISIBLE_DEVICES=0 /app/run serve-grpc --host 0.0.0.0 \
    --enable-editing-actors --renderer default --cache-size $cache \
    "${harm[@]}" --artifact-glob "$SHARD/*.usdz" > /tmp/serve.$1.log 2>&1 &
  SERVE_PID=$!
  # The scene list is CHECKED, never assumed: a renderer asked for a scene it
  # does not hold falls back to raster silently, and that reads as a
  # reconstruction problem rather than a configuration one.
  for _ in $(seq 1 180); do
    kill -0 $SERVE_PID 2>/dev/null || { say "serve exited early"; tail -40 /tmp/serve.$1.log; return 1; }
    grep -q "Available scenes" /tmp/serve.$1.log && break
    sleep 5
  done
  local scenes; scenes=$(grep "Available scenes" /tmp/serve.$1.log | tail -1)
  [ -n "$scenes" ] || { say "no scene list"; tail -40 /tmp/serve.$1.log; return 1; }
  for SC in "${MY_SCENES[@]}"; do
    echo "$scenes" | grep -q "$SC" || { say "MISSING scene $SC"; return 1; }
  done
  # The scene list is not readiness -- it is printed while the harmonizer
  # weights still load, and the port binds ~2 min later.
  for _ in $(seq 1 180); do grep -q "Serving on" /tmp/serve.$1.log && break; sleep 5; done
  grep -q "Serving on" /tmp/serve.$1.log || { say "never bound its port"; return 1; }
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3<&- 3>&-; break; }
    sleep 2
  done
  say "renderer up"
}
# `kill $SERVE_PID` alone does NOT stop the renderer. /app/run is a bash
# wrapper; the pycena binary it launches is a CHILD, so killing the wrapper
# orphans it to init and it keeps its ~19 GiB of scene cache on GPU 0. The next
# pass's server then starts ALONGSIDE it and the pass dies piecemeal with
# RESOURCE_EXHAUSTED -- cells failing at frame 0, and a server that "never bound
# its port" because there was no memory left to bind with. Measured on the
# 2026-09-04 run: six of ten shards carried an off-pass orphan into the on pass.
#
# So kill by pattern, then WAIT for the process to actually be gone rather than
# sleeping a fixed 10 s: the driver releases an allocation asynchronously and a
# fixed sleep is what made this look like a harmonizer memory problem.
kill_servers() {
  pkill -f "$SERVE_PAT" 2>/dev/null
  for _ in $(seq 1 30); do
    pgrep -f "$SERVE_PAT" >/dev/null || return 0
    sleep 2
  done
  say "server still up after SIGTERM; SIGKILL"
  pkill -9 -f "$SERVE_PAT" 2>/dev/null
  sleep 5
}
stop_serve() {
  [ -n "$SERVE_PID" ] && kill $SERVE_PID 2>/dev/null
  wait $SERVE_PID 2>/dev/null || true
  kill_servers
  SERVE_PID=""
  sleep 10
}
trap 'say exiting; kill $SERVE_PID 2>/dev/null; pkill -f "$SERVE_PAT" 2>/dev/null' EXIT

export PATH=/root/nexussim-venv/bin:$PATH
export PYTHONPATH="$REPO:$REPO/third_party:$REPO/third_party/nurec_protos"
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=$PORT NUREC_GRPC_TIMEOUT_S=600
export NEXUSSIM_NO_OVERLAY=1           # cam_f0.jpg = the renderer's own frame.
                                       # The HUD is burned in otherwise and FID
                                       # would score annotations, not pixels.
export PY123D_RECENTER=1 NEXUSSIM_NO_CAM_MAP_LINES=1
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export UV_NO_SYNC=1                     # ACCEPT_EULA is set above, before the
                                       # kitcache lookup imports isaacsim.

export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
export CUDA_VISIBLE_DEVICES=1 NEXUSSIM_NUREC_GPUS=1

gpu_is_gone() { grep -qE "cudaErrorInitializationError|CUDA driver initialization failed|no CUDA-capable device" "$1"; }

run_pass() {                          # $1 = on|off
  local tag=$1 out=$OUTROOT/h$1
  mkdir -p "$out"
  # A resumed shard whose pass is already complete should not pay two minutes
  # of scene enumeration to then skip every cell.
  local todo=0
  for T in "${MY[@]}"; do [ -f "$out/$T/.done" ] || todo=$((todo+1)); done
  if [ "$todo" -eq 0 ]; then say "pass $tag already complete (${#MY[@]} cells)"; return 0; fi
  say "pass $tag: $todo of ${#MY[@]} cells to do"
  start_serve "$tag" || exit 1
  local n=0 ok=0 skip=0 fail=0
  for T in "${MY[@]}"; do
    n=$((n+1))
    local D=$out/$T
    if [ -f "$D/.done" ]; then skip=$((skip+1)); continue; fi
    local STEPS=$STEPDIR/$T.txt
    [ -f "$STEPS" ] || { say "$T: no step list"; fail=$((fail+1)); continue; }
    local H; H=$($PY -m nexussim.navsafe handoff --token "$T" 2>>"$D.handoff.err" | tail -1) || true
    case "$H" in *NUREC_GRPC_HANDOFF*) eval "$H";; *) say "$T: no handoff"; fail=$((fail+1)); continue;; esac
    # Frames must span the manifest window, so the episode runs the whole
    # Arrow. ego-replay-frames >= the episode length is what makes it PURE
    # replay -- the policy is loaded (eval_py123d always loads one) but never
    # drives, so harmonizer on and off see identical camera poses.
    local NF; NF=$($PY - "$T" <<'PYX'
import sys, glob, pyarrow as pa, pyarrow.ipc as ipc
p=glob.glob(f"/avl-west/navsafe_5s_500/{sys.argv[1]}_20s/arrow/logs/*/*/sync.arrow")[0]
with pa.memory_map(p) as s: print(ipc.open_file(s).read_all().num_rows)
PYX
) || { say "$T: cannot size episode"; fail=$((fail+1)); continue; }
    rm -rf "$D"; mkdir -p "$D"
    NUREC_GRPC_RENDER_STEPS="@$STEPS" \
    NUREC_GRPC_TS_LOG="$D/render_timestamps.tsv" \
    $PY "$REPO/scripts/tools/eval_py123d.py" \
      --scenario-source py123d \
      --py123d-data-root "$CORPUS/${T}_20s/arrow" --py123d-scene-index 0 \
      --nurec-work-dir "$CORPUS" \
      --render-backend nurec_grpc --cam-height navsim \
      --model-type drivor \
      --checkpoint /avl-west/navsafe_eval/model_zoo/drivor/drivor_Nav1_25epochs.pth \
      --traffic-mode log_replay \
      --ego-replay-frames "$NF" --eval-frames 0 --eval-seed 1 \
      --controller lqr --execution-mode controller --replan-rate 5 \
      --camera-resolution-scale 1.0 \
      --nurec-cameras CAM_F0 --enable-vis \
      --log-level INFO --output-dir "$D" > "$D/eval.log" 2>&1 && rc=0 || rc=$?
    local got; got=$(ls -1 "$D/frames" 2>/dev/null | wc -l)
    if [ "$got" -ge 1 ]; then
      touch "$D/.done"; ok=$((ok+1)); say "[$tag $n/${#MY[@]}] $T OK ($got frames)"
    else
      fail=$((fail+1)); say "[$tag $n/${#MY[@]}] $T FAILED rc=$rc"
      gpu_is_gone "$D/eval.log" && { say "GPU is gone — failing the shard"; exit 3; }
    fi
  done
  say "pass $tag done: ok=$ok skip=$skip fail=$fail"
  stop_serve
}

run_pass off
run_pass on
say "ALL DONE"
