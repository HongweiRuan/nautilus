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
set -uo pipefail

: "${WORKER_INDEX:?}" "${WORKERS:?}" "${SEEDS:?}" "${NEXUSSIM_SHA:?}"
ROOT=/avl-west/navsafe_eval
SIMSCALE_ROOT=${SIMSCALE_ROOT:-$ROOT/aug_zoo/SimScale/source}
[ -f "$SIMSCALE_ROOT/traj_final/8192.npy" ] || { echo "SimScale assets missing; run prepare-assets.yaml first"; exit 1; }
DATASET=${DATASET:-$ROOT/dataset}
OUTROOT=${OUTROOT:-$ROOT/outputs}
MODELS_TSV=${MODELS_TSV:-/cfg/models.tsv}
ZOO=$ROOT/model_zoo
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
# TOKENS_FILE: restrict this run to an explicit token list instead of
# globbing the whole dataset. Used for targeted retries -- the 4 scenarios
# that never got a directory in the seed-1 rerun -- where scanning all 270
# would spend the renderer's start-up on scenarios already scored.
if [ -n "${TOKENS_FILE:-}" ]; then
  mapfile -t ALL_TOKENS < <(grep -vE '^[[:space:]]*(#|$)' "$TOKENS_FILE" | awk '{print $1}' | sort -u)
  say "TOKENS_FILE=$TOKENS_FILE -> ${#ALL_TOKENS[@]} token(s)"
else
mapfile -t ALL_TOKENS < <(
  for d in "$DATASET"/*/; do
    t=$(basename "$d")
    [ -f "$d/manifest.json" ] && [ -d "$d/arrow" ] || continue
    n=0; for f in "$d"/*.usdz; do [ -e "$f" ] && n=$((n+1)); done
    [ "$n" -ge 1 ] && echo "$t"
  done | sort
)
fi
[ "${#ALL_TOKENS[@]}" -eq 280 ] || { say "FATAL: expected exactly 280 canonical tokens, got ${#ALL_TOKENS[@]}"; exit 1; }
bundle_errors=0
for t in "${ALL_TOKENS[@]}"; do
  b="$DATASET/$t"
  n=0; for f in "$b"/*.usdz; do [ -e "$f" ] && n=$((n+1)); done
  if [ ! -f "$b/manifest.json" ] || [ ! -d "$b/arrow" ] || [ "$n" -ne 4 ]; then
    say "FATAL: incomplete bundle $b (manifest/arrow/4 usdz required)"
    bundle_errors=$((bundle_errors+1))
  fi
done
[ "$bundle_errors" -eq 0 ] || { say "FATAL: $bundle_errors of 280 bundles are incomplete"; exit 1; }
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
export UV_CACHE_DIR=/root/.cache/uv UV_PROJECT_ENVIRONMENT=/root/ns-venv
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
cp /cfg/gtrs_dense.py "$REPO/nexussim/policy/sensor/gtrs_dense.py"
sed -i '/"nexussim.policy.sensor.ltf",/a\    "nexussim.policy.sensor.gtrs_dense",' "$REPO/nexussim/engine/registry.py"
say "code at $(git -C "$REPO" log --oneline -1)"

cd "$REPO"
if ! /root/ns-venv/bin/python -c "import isaacsim, isaaclab, nexussim" 2>/dev/null; then
  say "uv sync (IsaacSim 6.0 + cu128 torch, ~15 min)"
  uv sync --all-extras --python 3.12 || { say "uv sync FAILED"; exit 1; }
  [ -d /root/IsaacLab/.git ] || git clone --depth 1 --branch v3.0.0-beta \
    https://github.com/isaac-sim/IsaacLab.git /root/IsaacLab
  for ext in isaaclab isaaclab_assets isaaclab_tasks isaaclab_rl isaaclab_mimic; do
    d=/root/IsaacLab/source/$ext
    [ -d "$d" ] && uv pip install --python /root/ns-venv/bin/python --no-deps -e "$d" >/dev/null
  done
  uv pip install --python /root/ns-venv/bin/python lazy_loader einops rasterio==1.4.3 retry==0.9.2 >/dev/null
  # SparseDriveV2 JIT-builds a CUDA extension (deformable attention) at its first
  # forward pass, and torch.utils.cpp_extension refuses to without ninja:
  # "Ninja is required to load C++ extensions". The NRE image ships nvcc 12.8 and
  # g++ but not ninja, so the cell died at frame 0 with an infra_failure that
  # reads like a broken adapter. Compiled once per pod into
  # /root/.cache/torch_extensions.
  uv pip install --python /root/ns-venv/bin/python ninja >/dev/null
fi
PY=/root/ns-venv/bin/python
"$PY" -c "import nexussim, isaaclab" || { say "venv unusable"; exit 1; }
# `uv sync` rewrites uv.lock in place — it normalises the environment markers for
# this platform, same package versions — and every eval then records itself as
# "launched from a DIRTY tree ... this run corresponds to no commit". Restoring
# the file is what lets run_meta.json name the commit these numbers came from;
# the installed set is the locked one either way, which is why this is safe.
git -C "$REPO" checkout -- uv.lock 2>/dev/null || true

NUPLAN_ROOT=/avl-west/navsafe_eval/aug_zoo/SimScale/nuplan-devkit
[ "$(git -C "$NUPLAN_ROOT" rev-parse HEAD 2>/dev/null)" = "ce3c323af01c0d7ec5672f7832ef53f9c679aab0" ] || {
  say "nuplan-devkit missing or not pinned to v1.2 commit ce3c323"; exit 1;
}

# The venv's bin/ has to be on PATH, not just its interpreter. torch checks for
# ninja by SHELLING OUT (`subprocess.run(["ninja", "--version"])` in
# verify_ninja_availability), so installing ninja into the venv while invoking
# only /root/ns-venv/bin/python leaves it invisible and SparseDriveV2 still dies
# at frame 0 with "Ninja is required to load C++ extensions". Checked here
# rather than trusted: the install is quiet, and its failure would otherwise
# surface 30 pods later as one adapter that never scores anything.
export PATH=/root/ns-venv/bin:$PATH
command -v ninja >/dev/null || { say "ninja not on PATH — sparsedrivev2 cannot JIT its CUDA extension"; exit 1; }
# The exact path torch will pass as -isystem, asked of the interpreter that will
# do the building rather than assumed from the apt package name.
INC=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
[ -f "$INC/Python.h" ] || { say "no Python.h under $INC — sparsedrivev2's extension cannot build"; exit 1; }
say "venv ready ($(git -C "$REPO" status --porcelain | wc -l) tracked files modified, ninja $(ninja --version), headers $INC)"

# ── 1b. VLA venv ──────────────────────────────────────────────────────────────
# The 6 subprocess-VLA rows in this sweep (recogdrive x2, mtdrive x2, autovla,
# drivelaw) run their model in a persistent subprocess under ONE shared venv
# (nexussim/policy/sensor/vla_client.py, NAVSAFE_VLA_PYTHON) built from the
# proven lockfile in navsafe_env_kit/envs/vla/ (captured 2026-08-26 from
# bolei-gpu07, where all these rows already ran successfully) — torch==2.10.0+
# cu128, transformers==4.57.6, same torch as the host venv. Kept separate from
# the host venv anyway because e.g. recogdrive/autovla need qwen_vl_utils and a
# specific transformers/diffusers combination the sim stack doesn't otherwise
# need. Built fresh on this pod's ephemeral /root, same as /root/ns-venv above
# — not cached on the PVC, ~5 min, paid once per pod.
#
# SimWAM (simwam/simwam_rl) is EXCLUDED from this sweep by models.tsv: its
# world-model load alone consumes the full ~23.5GB of a 3090 (confirmed via a
# standalone 1-GPU/80Gi-RAM Job — CUDA OOM in simwam.runtime.create_simwam),
# leaving nothing for this pod's second GPU (the renderer). The source
# machine had 8 GPUs and dedicated a whole one to NAVSAFE_VLA_GPU; our pods
# only get 2 total, so SimWAM does not fit here and is run elsewhere.
if grep -qE '^(recogdrive_il|recogdrive_rl|mtdrive_sft|mtdrive_mtgrpo|autovla|drivelaw|simwam|simwam_rl|drivevla_w0)\b' "$MODELS_TSV"; then
  VLA_LOCK=/avl-west/navsafe_eval/env_kit/vla_requirements.lock.txt
  VLA_EXTRA_LOCK=/avl-west/navsafe_eval/env_kit/vla_extra_site_requirements.lock.txt
  [ -f "$VLA_LOCK" ] || { say "VLA lockfile missing at $VLA_LOCK"; exit 1; }
  if [ ! -x /root/vla-venv/bin/python ]; then
    say "building vla-venv (torch 2.10.0+cu128 + transformers 4.57.6, ~5 min)"
    uv venv --python 3.12 /root/vla-venv >/dev/null || { say "vla-venv create FAILED"; exit 1; }
    # omegaconf==2.4.0.dev14 (a real PyPI prerelease) conflicts with
    # hydra-core==1.3.2's declared `omegaconf<2.4` under uv's strict resolver,
    # even though this exact pairing is what SimWAM/DriveLaW's Hydra configs
    # were proven against on the source machine — install everything else via
    # the resolver, then force this one package in after, same as the source
    # env's own pip almost certainly did.
    grep -v '^omegaconf==' "$VLA_LOCK" > /tmp/vla_reqs.txt
    uv pip install --python /root/vla-venv/bin/python \
      --extra-index-url https://download.pytorch.org/whl/cu128 \
      --index-strategy unsafe-best-match \
      -r /tmp/vla_reqs.txt || { say "vla-venv install FAILED"; exit 1; }
    uv pip install --python /root/vla-venv/bin/python --no-deps omegaconf==2.4.0.dev14 \
      || { say "vla-venv omegaconf FAILED"; exit 1; }
  fi
  export NAVSAFE_VLA_PYTHON=/root/vla-venv/bin/python
fi
if grep -q '^drivevla_w0\b' "$MODELS_TSV"; then
  /root/vla-venv/bin/python -c 'import tiktoken, scipy' 2>/dev/null || \
    uv pip install --python /root/vla-venv/bin/python tiktoken blobfile scipy \
      || { say "drivevla_w0 deps FAILED"; exit 1; }
fi
# RAP is BEVFormer + a DINO backbone, so it needs the OpenMMLab stack, which
# the sim venv does not carry: without it every rap cell dies at load with
# `ModuleNotFoundError: mmengine`. Three things this install has to get right,
# each measured on this image:
#
#  * --no-build-isolation. mmcv's setup.py imports pkg_resources without
#    declaring setuptools as a build dependency, so an isolated build cannot
#    even start. It also needs torch importable at build time, which isolation
#    would hide.
#  * mmcv PINNED to 2.1.0. 2.2.0 compiles and its CUDA ops load, but mmdet
#    asserts `mmcv>=2.0.0rc4, <2.2.0` at import and refuses it.
#  * a --target dir, not the venv. The build takes ~30 min of nvcc; keeping it
#    out of ns-venv means a failed or half-finished build cannot break the
#    other 14 rows, which import from ns-venv on every cell.
if grep -q '^rap\b' "$MODELS_TSV"; then
  if [ ! -d /root/mm_site/mmcv ]; then
    say "building the mmcv/mmdet stack for rap (~30 min of nvcc, once per pod)"
    mkdir -p /root/mm_site
    uv pip install --python /root/ns-venv/bin/python --target /root/mm_site \
      --no-build-isolation \
      --extra-index-url https://download.pytorch.org/whl/cu128 \
      --index-strategy unsafe-best-match \
      mmengine "mmcv==2.1.0" "mmdet>=3.0.0,<3.4" \
      || { say "mmcv stack FAILED — rap cells will fail, the rest are unaffected"; }
  fi
  # Appended (not prepended) at the PYTHONPATH assignment further down, so
  # ns-venv's own torch/numpy keep winning over anything mmdet pulled in.
  export MM_SITE=/root/mm_site
  if PYTHONPATH=/root/mm_site /root/ns-venv/bin/python -c "from mmcv.ops.multi_scale_deform_attn import MultiScaleDeformableAttention" 2>/dev/null; then
    say "mmcv stack ready (rap enabled)"
  else
    say "WARNING: mmcv stack did not import — rap cells will fail at load"
  fi
fi

if grep -q '^drivelaw\b' "$MODELS_TSV"; then
  # DriveLaW's navsim fork imports nuplan.common.actor_state beyond what
  # drivelaw_server.py's own stub covers; the real devkit has to be
  # importable. Installed --no-deps into a side site-dir (not into vla-venv
  # itself) so its own transitive deps never shadow vla-venv's torch/numpy for
  # the other 5 VLA rows sharing that venv.
  [ -d /root/vla_extra_site ] || {
    mkdir -p /root/vla_extra_site
    uv pip install --target /root/vla_extra_site --no-deps -r "$VLA_EXTRA_LOCK" \
      || { say "vla_extra_site FAILED"; exit 1; }
  }
  export NAVSAFE_VLA_EXTRA_PYTHONPATH=/root/vla_extra_site
  [ -f /avl-west/navsafe_eval/model_zoo/drivelaw/inference_front.yaml ] || \
    sed -e "s|\${DRIVELAW_ZOO}|/avl-west/navsafe_eval/model_zoo/drivelaw|g" \
        -e "s|\${DRIVELAW_REPO}|/avl-west/navsafe_eval/vla_repos/drivelaw|g" \
        /avl-west/navsafe_eval/model_zoo/drivelaw/inference_front.template.yaml \
        > /avl-west/navsafe_eval/model_zoo/drivelaw/inference_front.yaml
fi

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
# Seeds 0/1024 render under the RECON rig: the reconstruction's own
# training CameraSpec and baked cam->rig, preserving calibrated
# distortion, native extent and observed rays. `navsim` rebuilds a
# zero-distortion pinhole the recon was never fit on; nurec_grpc.py
# calls it a legacy compatibility path, not the quality default.
# Overridable so the A/B stays available.
export NUREC_GRPC_CAM_RIG=${NUREC_GRPC_CAM_RIG:-recon} NUREC_GRPC_TIMEOUT_S=600
export PY123D_RECENTER=1
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NEXUSSIM_NO_CAM_MAP_LINES=1
# NB: this REPLACES PYTHONPATH, so anything set earlier (the rap mm stack at
# section 1c) has to be re-appended here rather than exported above -- an
# export before this line is silently discarded.
export PYTHONPATH="$SIMSCALE_ROOT:$NUPLAN_ROOT:$REPO:$REPO/third_party/nurec_protos${MM_SITE:+:$MM_SITE}"
"$PY" -c "from nuplan.common.actor_state.ego_state import EgoState; from nuplan.common.maps.abstract_map import SemanticMapLayer; from navsim.agents.gtrs_dense.hydra_config import HydraConfig; from navsim.agents.gtrs_dense.hydra_model import HydraModel" || { say "SimScale GTRS dependency import FAILED"; exit 1; }
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES UV_NO_SYNC=1
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
export CUDA_VISIBLE_DEVICES=1 NEXUSSIM_NUREC_GPUS=1
# vla_client.py defaults NAVSAFE_VLA_GPU to "7" (the source machine's 8th
# GPU); this pod only has 2 (0=renderer, 1=main eval). Left unset, the VLA
# subprocess's CUDA_VISIBLE_DEVICES=7 resolves to no visible device at all --
# "RuntimeError: No CUDA GPUs are available" on every VLA row, confirmed
# 2026-08-27. Share GPU 1 with the main eval process, not GPU 0 (the
# renderer) -- matches the smoke-tested models comfortably fitting a single
# 3090 standalone.
# SimWAM's world model alone fills a 3090 (~23.5GB), so it cannot share GPU 1
# with the main eval process the way the smaller VLA rows do. This pod requests
# a THIRD GPU for exactly that: 0 renderer, 1 eval, 2 the VLA server.
# The six remaining VLA rows are small enough to share GPU 1 with the eval, as
# they always did; the third card was only ever for SimWAM, which is dropped.
if [ "$(nvidia-smi -L 2>/dev/null | wc -l)" -ge 3 ]; then
  export NAVSAFE_VLA_GPU=2
else
  export NAVSAFE_VLA_GPU=1
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
metrics_scored() {
  "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); s=d.get("metrics",{}).get("driving_score"); raise SystemExit(0 if d.get("status")=="scored" and type(s) in (int,float) else 1)' "$1" 2>/dev/null
}

gpu_is_gone() {
  grep -qE "cudaErrorInitializationError|CUDA driver initialization failed|no CUDA-capable device|CUDA unknown error" "$1"
}
for T in "${MY_TOKENS[@]}"; do
  B="$DATASET/$T"
  HANDOFF=$("$PY" -m nexussim.navsafe.eval.bundle --handoff "$B" 2>/dev/null)
  [ -n "$HANDOFF" ] || { say "$T: no handoff, skipping scenario"; fail_n=$((fail_n+1)); continue; }
  export NUREC_GRPC_HANDOFF="$HANDOFF"

  # ── which arrow does this scenario score against? ─────────────────────────
  # An EDITED scenario is scored against the PUBLISHED window at
  # /avl-west/navsafe_release/<token>/arrow. The recipes were rebaked to that
  # window (816b710 set frames.T 216->200/201, 541f993 rebaked timestamps);
  # replaying them on the corpus `<token>_20s` arrow (216 frames) now raises
  #   spawn_reactive_actor: ... baked for T=200 frames but this host has 216
  # and killed shards w01/w02/w03/w11/w12 on 2026-09-03. This mirrors
  # run_figure2_worker.sh, which scored all 16 fig2 recipes this way.
  #
  # The reconstructions still come from the corpus (--nurec-work-dir): the
  # published usdz are byte-identical, and the release dirs hold only arrow/
  # and manifest.json. The asset-harvester replace manifest likewise stays in
  # the corpus _20s dir. No recipe -> the published bundle, unchanged.
  RECIPE_DIR="$REPO/nexussim/navsafe/recipes/benchmark"
  DATA_ROOT="$B/arrow"
  AH_BASE="$B"
  WORKDIR_ARGS=()
  if compgen -G "$RECIPE_DIR/*.$T.yaml" > /dev/null; then
    W20="/avl-west/navsafe_5s_500/${T}_20s"
    REL="/avl-west/navsafe_release/$T"
    if [ -d "$REL/arrow" ] && [ -d "$W20" ]; then
      DATA_ROOT="$REL/arrow"
      AH_BASE="$W20"
      WORKDIR_ARGS=(--nurec-work-dir /avl-west/navsafe_5s_500)
      say "$T: EDITED -> scoring against navsafe_release/$T/arrow (recon + ah_assets from ${T}_20s)"
    elif [ -d "$B/arrow" ] && [ -d "$W20" ]; then
      # V-8 postdates the navsafe_release mirror, so its tokens have no
      # $REL/arrow. The bundle's own arrow/ is the SAME trimmed layout --
      # verified byte-identical to the release copy on a token present in
      # both (custom.scenario.arrow 40122 = 40122), unlike ${T}_20s/arrow
      # which still carries the camera arrays. Use it, keeping ah_assets and
      # the reconstructions where they always were.
      DATA_ROOT="$B/arrow"
      AH_BASE="$W20"
      WORKDIR_ARGS=(--nurec-work-dir /avl-west/navsafe_5s_500)
      say "$T: EDITED -> scoring against dataset/$T/arrow (no release mirror; ah_assets from ${T}_20s)"
    else
      say "$T: has a recipe but no $REL/arrow or $W20; skipping (a recipe cannot replay elsewhere)"
      fail_n=$((fail_n+1)); continue
    fi
  fi

  for ROW in "${ROWS[@]}"; do
    IFS=$'\t' read -r SLUG MT CK EXTRA_ENV <<< "$ROW"
    # The augmentation rows live outside the zoo (see models_final18.tsv), so
    # an absolute checkpoint column is passed through unchanged.
    case "$CK" in
      none) CKPT=none ;;
      /*)   CKPT="$CK" ;;
      *)    CKPT="$ZOO/$CK" ;;
    esac
    # drivelaw's "checkpoint" column is the materialised inference config
    # (--config), not a weights file — the adapter passes checkpoint_path
    # straight through as --config (nexussim/policy/sensor/drivelaw.py).

    # Row 4 (extra_env: comma-separated KEY=VAL pairs) carries per-model data
    # paths (NAVSAFE_RECOGDRIVE_VLM, NAVSAFE_AUTOVLA_BASE/REPO,
    # NAVSAFE_DRIVELAW_REPO). NAVSAFE_VLA_PYTHON/NAVSAFE_VLA_EXTRA_PYTHONPATH
    # are NOT per-row: one shared vla-venv serves every VLA row, exported once
    # in section 1b. Unset the per-row vars first so one VLA row's paths never
    # leak into the next row or into a non-VLA row that follows it.
    unset NAVSAFE_RECOGDRIVE_VLM NAVSAFE_AUTOVLA_BASE NAVSAFE_AUTOVLA_REPO \
          NAVSAFE_DRIVELAW_REPO NAVSAFE_SIMWAM_REPO NAVSAFE_RESWORLD_REPO \
          NAVSAFE_DRIVEVLA_W0_REPO NAVSAFE_DRIVEVLA_W0_VLM NAVSAFE_DRIVEVLA_W0_VQ \
          NAVSAFE_DRIVEVLA_W0_ACTION_TOKENIZER NAVSAFE_DRIVEVLA_W0_NORM_STATS \
          NAVSAFE_PRIOREYE_EMBEDDING \
          DIFFSYNTH_MODEL_BASE_PATH DIFFSYNTH_DOWNLOAD_SOURCE
    if [ -n "$EXTRA_ENV" ]; then
      IFS=',' read -ra _KVS <<< "$EXTRA_ENV"
      for _KV in "${_KVS[@]}"; do export "${_KV?}"; done
    fi

    for SEED in $SEEDS; do
      OUT="$OUTROOT/$SLUG/seed$SEED/$T"
      LOG="$OUTROOT/$SLUG/seed$SEED/$T.log"
      # Resume guard. The DONE line + a metrics file is NOT enough on its own:
      # an infra_failure cell writes both, with status "excluded" and a null
      # driving_score, so a plain existence check treats a renderer OOM as
      # finished work and the retry silently skips every cell it was launched
      # for (measured: ok=0 skipped=6). RETRY_EXCLUDED=1 additionally requires
      # a non-null driving_score, so only genuinely scored cells are skipped.
      if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && metrics_scored "$OUT/navsafe_metrics.json"; then
        skip_n=$((skip_n+1)); continue
      elif [ -f "$OUT/navsafe_metrics.json" ]; then
        say "  $T: previous output is not a valid scored result -- retrying"
      fi
      serve_alive || { say "renderer died — restarting"; kill $SERVE_PID 2>/dev/null; start_serve || exit 1; }

      mkdir -p "$OUT"
      say "$SLUG seed$SEED $T"
      # --asset-harvester-replace is PER SCENARIO: 248 of the 270 published
      # bundles carry ah_assets/replace_manifest.json and 22 do not (they have
      # none on the Hub either -- scenarios with no inserted actors). The bare
      # flag resolves the bank beside the data root and ap.error()s when it is
      # absent, so passing it unconditionally would kill a fifth of the sweep
      # at argument parsing.
      # Pass the manifest PATH, never the bare flag. With no value the eval
      # resolves the bank from --py123d-data-root's parent, which for an
      # edited scenario is the corpus dir and not the bundle -- it then
      # ap.error()s on a path that was never going to exist, killing the cell
      # at argument parsing and, after seven in a row, the whole shard.
      AH=()
      _ahm="$AH_BASE/ah_assets/replace_manifest.json"
      [ -f "$_ahm" ] && AH=(--asset-harvester-replace "$_ahm")
      # Up to CELL_TRIES attempts per cell. On a 24 GB 3090 the renderer sits
      # a few hundred MB under the ceiling, so a scene occasionally fails to
      # build (infra_failure at frame 0) or CUDA context creation returns
      # error 999 -- both are transient, both clear on a retry once the
      # previous process has released its memory. Measured 2026-09-04: of the
      # 14 tokens that ever hit infra_failure, 12 had already scored 29-30 of
      # their 30 cells, i.e. a ~3% per-cell dice roll, not a bad scenario.
      # Retrying in place costs 30 s; the old behaviour (exit 1, reschedule
      # the Job onto another node) cost a ~25 min bootstrap for the same
      # outcome.
      cell_ok=0
      for _try in $(seq 1 "${CELL_TRIES:-4}"); do
        [ "$_try" -gt 1 ] && {
          say "  retry $_try/${CELL_TRIES:-4} after transient failure"
          sleep 30
          serve_alive || { say "  renderer gone — restarting"; kill $SERVE_PID 2>/dev/null; start_serve || exit 1; }
        }
        timeout --signal=KILL "$CELL_TIMEOUT" \
          "$PY" "$REPO/scripts/tools/eval_py123d.py" \
            --scenario-source py123d --py123d-data-root "$DATA_ROOT" --py123d-scene-index 0 \
            "${WORKDIR_ARGS[@]}" \
            --render-backend nurec_grpc --cam-height navsim \
            --model-type "$MT" --checkpoint "$CKPT" \
            --traffic-mode semi_reactive \
            --recipe-dir "$RECIPE_DIR" \
            "${AH[@]}" \
            --ego-replay-frames 20 \
            --terminate-on-collision \
            --controller lqr --execution-mode controller \
            --replan-rate 5 --camera-resolution-scale 1.0 \
            --eval-frames 600 \
            --eval-seed "$SEED" \
            --navsafe-prune-artifacts \
            --output-dir "$OUT" > "$LOG" 2>&1
        if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && metrics_scored "$OUT/navsafe_metrics.json"; then
          cell_ok=1; break
        fi
        # CUDA would not initialise at all. On a healthy node this is the
        # transient error-999 context race and a retry clears it; if it is
        # still failing on the last attempt the node itself is unusable, and
        # the check below hands the slice back.
        gpu_is_gone "$LOG" && say "  CUDA init failed (error 999)"
      done
      if [ "$cell_ok" != 1 ] && gpu_is_gone "$LOG"; then
        say "GPU UNUSABLE on $(hostname) after ${CELL_TRIES:-4} tries — failing so the Job reschedules"
        exit 1
      fi
      if [ "$cell_ok" = 1 ]; then
        done_n=$((done_n+1)); consec_fail=0; say "  OK"
      else
        # ${CELL_TRIES:-4} attempts all failed. Whatever is wrong with this
        # scenario is not transient, so skip the WHOLE token (its remaining
        # model x seed cells would fail the same way) and move on. The worker
        # never exits on a scenario's account -- a shard is worth ~18 tokens
        # and must not be thrown away for one of them, which is exactly how
        # w05/w07r/w13 were lost on 2026-09-04.
        fail_n=$((fail_n+1)); consec_fail=$((consec_fail+1))
        say "  FAILED after ${CELL_TRIES:-4} tries (see $LOG) — skipping token $T"
        tail -5 /tmp/serve.log > "$OUTROOT/$SLUG/seed$SEED/$T.serve.log" 2>/dev/null
        # A whole node whose driver has gone bad fails EVERY cell in seconds;
        # that is an environment fault, not a scenario, so hand the slice back
        # and let the Job reschedule it (backoffLimit is 4). The threshold is
        # deliberately far above one token's 30 cells.
        if [ "$consec_fail" -ge 20 ]; then
          say "ABORT: $consec_fail consecutive failures — this node looks unusable"
          exit 1
        fi
        break 2
      fi
    done
  done
done

say "WORKER DONE ok=$done_n skipped=$skip_n failed=$fail_n"
# A worker that finished its slice exits 0 even with failed cells: the Job must
# not retry a whole 6 h pod because one scenario is broken. status.sh is what
# reports the holes.
exit 0
