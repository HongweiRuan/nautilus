#!/bin/bash
# One scenario of the Figure 2 campaign: render a NavSafe edited scenario under
# closed-loop DrivoR control and keep every camera frame.
#
# These runs exist to be SCREENSHOT, not scored. Two consequences run through
# the script:
#
#  * The camera frames must be the renderer's own pixels. NEXUSSIM_NO_OVERLAY
#    and NEXUSSIM_NO_CAM_MAP_LINES keep the HUD and the projected lane lines
#    off them, so a crop lands in the paper without retouching. The BEV that
#    Figure 2 pairs with each frame comes from --enable-vis, which writes a
#    separate image and is unaffected.
#  * A renderer asked for a scene it does not hold falls back to raster
#    SILENTLY. On a metrics run that shows up as a bad number; on a figure run
#    it is a blurry panel nobody notices until review. So the scene list is
#    checked against this host's four reconstructions before the rollout, and
#    the job fails rather than renders something else.
#
# Env: TARGET (<leaf>.<token>), OUTROOT, and optionally CORPUS / RECIPE_DIR.
set -eo pipefail

TARGET=${TARGET:?TARGET=<leaf>.<token> is required}
T=${TARGET#*.}                                   # the 16-hex nuPlan token
LEAF=${TARGET%%.*}
CORPUS=${CORPUS:-/avl-west/navsafe_5s_500}
# The scenario the eval READS is the PUBLISHED Arrow, not the corpus one.
#
# They are the same bytes for 45 of the 80 hosts and a different LENGTH for the
# other 35: the corpus Arrow runs 16-20 frames past what was published, i.e.
# past what the four reconstructions cover, and the frozen recipes are cut to
# the published window. Replay refuses the difference outright --
#   spawn_reactive_actor: ... baked for T=200 frames but this host has 216
# -- which is how four of these sixteen failed on 2026-09-02.
#
# Fixing the CORPUS copy would have been equivalent and is what fetch_bundle.py
# does, but all 35 are in the fidelity evalrender campaign's scenario list,
# which is mid-flight and renders each scenario twice expecting identical camera
# poses. So the published bytes live beside the corpus and only a `--recipe`
# eval reads them. The reconstructions still come from the corpus -- those are
# byte-identical to the published usdz.
RELEASE=${RELEASE:-/avl-west/navsafe_release}
REPO=${REPO:-/hugsim-storage/NexusSim}
RECIPE_DIR=${RECIPE_DIR:-$REPO/nexussim/navsafe/recipes/benchmark}
RECIPE=$RECIPE_DIR/$TARGET.yaml
CKPT=${CKPT:-/avl-west/navsafe_eval/model_zoo/drivor/drivor_Nav1_25epochs.pth}
OUTROOT=${OUTROOT:-/avl-west/runs/20260902-paper-figure2-drivor}
OUT=$OUTROOT/$TARGET
REPLAY_FRAMES=${REPLAY_FRAMES:-20}
EVAL_FRAMES=${EVAL_FRAMES:-180}
PORT=8080

say() { echo "[$TARGET $(date +%H:%M:%S)] $*"; }
trap 'echo "=== serve-grpc tail ==="; tail -60 /tmp/serve.log 2>/dev/null || true' EXIT

# ── 0. preflight ─────────────────────────────────────────────────────────────
# Every one of these has cost a job forty minutes of environment build before
# failing, so they are answered in the first two seconds instead.
test -s "$CKPT"   || { say "FATAL: no DrivoR checkpoint at $CKPT"; exit 1; }
test -s "$RECIPE" || { say "FATAL: no recipe at $RECIPE"; exit 1; }
test -d "$RELEASE/$T/arrow" || { say "FATAL: no published Arrow at $RELEASE/$T/arrow -- run /avl-west/navsafe_dev/fetch_release_arrow.py"; exit 1; }
N=$(ls "$CORPUS/$T"s?/output_5cam/*/artifacts/last.usdz 2>/dev/null | wc -l)
[ "$N" = 4 ] || { say "FATAL: $T has $N/4 reconstructions"; exit 1; }
grep -q "^leaf: $LEAF$" "$RECIPE" || { say "FATAL: $RECIPE is not a $LEAF recipe"; exit 1; }
say "preflight OK (recipe $(basename "$RECIPE"), published Arrow, 4 reconstructions)"

# ── 1. environment ───────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
say "apt: the GL/X libs the renderer and IsaacSim need"
apt-get update -qq && apt-get install -y -qq git curl python3-venv python3-dev \
  libglu1-mesa libxt6 libgl1 libglx0 libegl1 libglib2.0-0 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxext6 libxrender1 libx11-6 libxfixes3 libxdamage1 libsm6 \
  libice6 libgomp1 >/dev/null || { say "FATAL: apt failed"; exit 1; }

export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
# POD-LOCAL uv cache, exactly as pods/horuan-nexussim.yaml does it, NOT the
# 62 GB one on /avl-west. The PVC cache is on a different filesystem from the
# venv, so uv cannot hardlink and copies all ~360 packages -- torch and
# IsaacSim included -- which is where the editing90 jobs' ~40 min went. A
# pod-local cache downloads instead, ~15 min, and sixteen jobs downloading in
# parallel beats sixteen reading 62 GB off CephFS at once.
export UV_CACHE_DIR=/root/.cache/uv
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES

# The SHARED venv on the PVC, or build one. A build costs ~15 min with the GPU
# idle -- see the cache note above for why it is 15 and not 40.
#
# CHECKED 2026-09-02: /avl-west/navsafe_dev/ns-venv, which the editing90 jobs
# reused, NO LONGER EXISTS, and /avl-west/navsafe_bundle_repo/venv is a py3.11
# venv whose interpreter symlink dangles in this image. So every job builds its
# own, the same `uv sync` pods/horuan-nexussim.yaml runs (~15 min). The probe is
# left in place so a shared venv that reappears is picked up without editing
# this script; extra candidates go in SHARED_VENVS.
#
# `import isaacsim` PROMPTS for the Omniverse licence, so the probe needs
# ACCEPT_EULA (exported above). Without it the probe answered "this venv is
# broken" for a venv that works, and every job rebuilt its own anyway.
VENV=/root/nexussim-venv
for CAND in ${SHARED_VENVS:-/avl-west/navsafe_dev/ns-venv}; do
  [ -x "$CAND/bin/python" ] || continue
  "$CAND/bin/python" -c "import isaacsim, isaaclab, nexussim" 2>/dev/null || continue
  VENV=$CAND; say "using the shared venv at $VENV"; break
done
if [ "$VENV" = /root/nexussim-venv ]; then
  say "no shared venv; building one (the same uv sync the workspace pod runs, ~15 min)"
fi
export UV_PROJECT_ENVIRONMENT=$VENV VIRTUAL_ENV=$VENV
if [ "$VENV" = /root/nexussim-venv ]; then
  for i in 1 2 3 4; do
    command -v uv >/dev/null && break
    python -m pip install --quiet --user uv 2>/dev/null \
      || curl -LsSf https://astral.sh/uv/install.sh | sh
    hash -r; sleep 10
  done
  command -v uv >/dev/null || { say "FATAL: uv unavailable"; exit 1; }
  cd "$REPO"
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
"$PY" -m pip install --quiet grpcio protobuf 2>&1 | tail -1 || true

# ── 2. warm the Omniverse Kit shader/material cache ──────────────────────────
# The minutes an eval spends before it evaluates anything are NOT the venv --
# they are Kit compiling materials (omni.ujitso) and ray-tracing pipelines
# (RtPso) inside AppLauncher, on an EMPTY stage, writing the results to caches
# that die with the pod. Measured 2026-08-31: AppLauncher returned after 467 s
# cold and 10.5 s with these restored. The compile finishes before the scenario
# is read, so one cache serves the whole run.
#
# The tar is keyed on DRIVER VERSION (the OptiX and Vulkan pipeline caches are)
# and its members are venv-agnostic: `kit/` unpacks into whichever isaacsim
# package this venv has, `var/` and `root/` into /. A miss is not a failure --
# Kit just recompiles -- so nothing here aborts the job.
#
# To refresh after an IsaacSim upgrade, a driver change or a new GPU model, run
# one eval to completion in a pod and repack from that pod:
#   KITPKG=$($PY -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))")
#   DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | tr -d ' ')
#   tar -cf /avl-west/navsafe_dev/kitcache/kitcache-3090-$DRV.tar \
#       -C "$KITPKG" kit -C / var/tmp/OptixCache_root root/.cache/ov root/.cache/warp root/.nv
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ')
KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$DRV.tar
if [ -f "$KITCACHE" ]; then
  KITPKG=$("$PY" -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))" 2>/dev/null)
  if [ -n "$KITPKG" ] && tar -xf "$KITCACHE" -C "$KITPKG" kit && tar -xf "$KITCACHE" -C / var root; then
    say "Kit shader cache restored into $KITPKG (saves ~7.6 min of boot)"
  else
    say "Kit cache restore failed; IsaacSim will recompile (~8 min)"
  fi
else
  say "no Kit cache for driver $DRV; IsaacSim will recompile (~8 min)"
fi

# ── 3. the renderer ──────────────────────────────────────────────────────────
# This host's four sub-clips only. serve-grpc reads every artifact the glob
# finds at start-up, so pointing it at the whole corpus would make each job scan
# 1632 usdz over CephFS to serve four.
#
# One GPU serves both the renderer and the rollout: measured ~6.7 GB together on
# a 3090 with the harmonizer OFF. Turning the harmonizer on needs a second GPU
# (its weights sit beside the scene cache and take serve-grpc to ~18 GB), which
# is why it is not on here -- and the benchmark's own renders are harmonizer-off
# too, so these frames match the rest of the paper.
say "starting serve-grpc"
CUDA_VISIBLE_DEVICES=0 /app/run serve-grpc --host 0.0.0.0 \
  --enable-editing-actors --renderer default --cache-size 4 \
  --artifact-glob "$CORPUS/${T}s?/output_5cam/*/artifacts/last.usdz" \
  > /tmp/serve.log 2>&1 &
SERVE_PID=$!

for _ in $(seq 1 180); do
  kill -0 $SERVE_PID 2>/dev/null || { say "FATAL: serve-grpc exited early"; exit 1; }
  grep -q "Available scenes" /tmp/serve.log && break
  sleep 5
done
SCENES=$(grep "Available scenes" /tmp/serve.log | tail -1)
[ -n "$SCENES" ] || { say "FATAL: serve-grpc printed no scene list"; exit 1; }
# CHECKED, never assumed -- see the header. A missing sub-clip renders as raster.
for s in 1 2 3 4; do
  echo "$SCENES" | grep -q "${T}s$s" || { say "FATAL: renderer is missing scene ${T}s$s"; exit 1; }
done
# The scene list is not readiness: it prints while the port is still unbound.
for _ in $(seq 1 180); do grep -q "Serving on" /tmp/serve.log && break; sleep 5; done
grep -q "Serving on" /tmp/serve.log || { say "FATAL: serve-grpc never bound its port"; exit 1; }
for _ in $(seq 1 60); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3<&- 3>&-; break; }
  sleep 2
done
say "renderer up, all four reconstructions present"

# ── 4. the rollout ───────────────────────────────────────────────────────────
# `nre` -- the renderer's generated proto stubs -- lives in
# third_party/nurec_protos. Pointing at third_party alone import-errors inside
# `nurec_grpc.setup`, minutes in, after IsaacSim has booted.
export PYTHONPATH=$REPO:$REPO/third_party:$REPO/third_party/nurec_protos
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=$PORT
export NUREC_GRPC_CAM_RIG=navsim NUREC_GRPC_TIMEOUT_S=600
export PY123D_RECENTER=1 NAVSAFE_WORK=/avl-west/navsafe_dev
export NEXUSSIM_NO_OVERLAY=1 NEXUSSIM_NO_CAM_MAP_LINES=1
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
export CUDA_VISIBLE_DEVICES=0 NEXUSSIM_NUREC_GPUS=1

# The hand-off says which of the four reconstructions owns each frame. Derived
# here rather than written into the Job, because it carries absolute paths that
# are only valid on the machine that reads them.
H=$("$PY" -m nexussim.navsafe handoff --token "$T" 2>/dev/null | tail -1)
case "$H" in *NUREC_GRPC_HANDOFF*) eval "$H";; *) say "FATAL: no hand-off for $T"; exit 1;; esac

mkdir -p "$OUT"
say "rollout: ${REPLAY_FRAMES} replay + ${EVAL_FRAMES} eval frames under DrivoR"
"$PY" "$REPO/scripts/tools/eval_py123d.py" \
  --scenario-source py123d \
  --py123d-data-root "$RELEASE/$T/arrow" --py123d-scene-index 0 \
  --nurec-work-dir "$CORPUS" \
  --render-backend nurec_grpc --cam-height navsim \
  --model-type drivor --checkpoint "$CKPT" \
  --recipe "$RECIPE" \
  --traffic-mode navsafe \
  --ego-replay-frames "$REPLAY_FRAMES" --eval-frames "$EVAL_FRAMES" --eval-seed 1 \
  --terminate-on-collision \
  --execution-mode controller --controller lqr --replan-rate 5 \
  --camera-resolution-scale 1.0 \
  --enable-vis --vis-cameras CAM_L0,CAM_B0 \
  --nurec-cameras CAM_F0,CAM_B0,CAM_L0 \
  --log-level INFO --output-dir "$OUT" 2>&1 | tee "$OUT/eval.log"
rc=${PIPESTATUS[0]}

kill $SERVE_PID 2>/dev/null || true
GOT=$(ls -1 "$OUT/frames" 2>/dev/null | wc -l)
say "rc=$rc, $GOT camera frames in $OUT/frames"
[ "$GOT" -ge 1 ] || { say "FATAL: no frames rendered"; exit 1; }
test -f "$OUT/navsafe_metrics.json" || say "WARNING: no navsafe_metrics.json (the episode ended early)"
touch "$OUT/.done"
say "FIGURE2_DONE $TARGET"
