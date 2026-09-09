#!/usr/bin/env bash
# One worker of the hand-off perturbation sweep: a renderer and a sequential
# eval loop over this worker's slice of the SELECTED scenarios, inside one pod
# on two 3090s.
#
# What this campaign is. For each of the 27 populated taxonomy leaves, the two
# least-crowded scenarios that survived offline screening are driven 19 times
# per model: once unperturbed, and once for each rigid displacement of the ego
# on the HAND-OFF frame -- the first frame the policy owns the car. Lateral
# +/-0.5/1.0/1.5 m, longitudinal +/-0.5/1.0/1.5 m, yaw +/-15/30/45 deg. Every arm
# shares an identical replay prefix, so the only thing that differs is the pose
# the policy is handed, and the artifact that answers the question is
# plan_records.json: every candidate trajectory, the pick, and the pose the ego
# actually reached.
#
# It is derived from the seed-1 rerun worker (ConfigMap navsafe-rerun-cfg),
# and every environment/venv/renderer section below is copied from it verbatim
# because those are what make a cell run at all. What is DIFFERENT, and why:
#
#  * The unit of work is a (scenario, arm, model) CELL, not (scenario, model).
#    Nesting is scenario -> arm -> model so the renderer keeps one scenario's
#    four reconstructions resident across all 95 of its cells.
#
#  * --enable-vis --vis-cameras CAM_L0,CAM_R0,CAM_B0. The demo shows the front
#    camera changing as the slider moves, and the surround views are what let a
#    viewer see WHY. This costs three extra renders per frame; it is the point
#    of the campaign, not an option.
#
#  * NO --navsafe-prune-artifacts. The pruned files (driving_score_summary.csv
#    in particular) carry the per-frame contact and drivable-area flags, and a
#    perturbation plot that cannot say which arms crashed is not worth drawing.
#
#  * The scenario list, its per-scenario hand-off frame and its data root all
#    come from /cfg/selection.json, written by the offline screening pass
#    (pick_demo_scenarios.py). The hand-off is NOT assumed to be 20: 7 of the 8
#    edited leaves carry recipes frozen at replay_frames 8, and eval_py123d
#    honours the recipe. The perturbation lands on whatever that resolved frame
#    is, which is what "the first policy-takeover frame" means.
#
#  * THE GPU LAYOUT FOLLOWS THE POD, not a constant. A worker given one card runs
#    the renderer and the rollout on it at --cache-size 2; a worker given two
#    keeps the renderer alone on GPU 0 at --cache-size 4 and puts IsaacSim and
#    the policy server on GPU 1. Deriving it from `nvidia-smi -L` rather than an
#    env var means the manifest cannot disagree with the script.
#
#    Why share at all: measured over 147 samples per card, the renderer's GPU sat
#    at 19.8% and the rollout's at 6.6%, against Nautilus's >40% floor. Neither
#    process saturates a card -- the eval main thread spends 87.5% of its samples
#    in S, waiting on the render round-trip -- so the second card bought latency,
#    not throughput, and cost the account its submission quota.
#
#    Why not share for every model: the renderer at --cache-size 4 measured 21.8
#    of 23.6 GiB, and at 2 it is roughly half that; IsaacSim and a small policy
#    add 4.0-6.6 GiB, which fits. SimWAM does not -- it needs 13.7 GiB of its own
#    (measured 2026-09-06), and 12 + 13.7 + 5 overruns a 3090. So the simwam row
#    runs as its own two-card fleet, with MODELS_TSV pointing at its own list.
#
#    Edited scenarios require cache-size 4; plain scenarios may use 2.
#    Resource profiles live in config/campaign.json.
#
# Inputs, all from the Job manifest:
#   WORKER_INDEX  this worker's index, 0-based
#   WORKERS       how many workers share the scenario set
#   SEEDS         space-separated --eval-seed values
#   NEXUSSIM_SHA  the commit every worker in the campaign evaluates
#   MODELS_TSV    which model list to run (default /cfg/models.tsv; the simwam
#                 fleet points this at /cfg/models_simwam.tsv)
set -uo pipefail

: "${WORKER_INDEX:?}" "${WORKERS:?}" "${SEEDS:?}" "${NEXUSSIM_SHA:?}"

# How many cards this pod actually got decides the layout. See the note above.
N_GPU=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ')
if [ "${N_GPU:-1}" -ge 2 ]; then
  RENDER_CACHE=4; EVAL_GPU=1; GPU_LAYOUT="$N_GPU cards, rollout on GPU $EVAL_GPU"
else
  RENDER_CACHE=2; EVAL_GPU=0;             GPU_LAYOUT="1 card, shared with the rollout"
fi
ROOT=/avl-west/navsafe_eval
OUTROOT=${OUTROOT:-/avl-west/navsafe_eval/perturb_outputs}
MODELS_TSV=${MODELS_TSV:-/cfg/models.tsv}
SELECTION=${SELECTION:-/cfg/selection.json}
ZOO=$ROOT/model_zoo
HARMONIZER_CACHE=${HARMONIZER_CACHE:-/avl-west/navsafe_dev/.harmonizer-cache}
PORT=8080
CELL_TIMEOUT=${CELL_TIMEOUT:-45m}
W=$(printf 'w%02d' "$WORKER_INDEX")

say() { echo "[$W $(date -u +%H:%M:%S)] $*"; }

# ── 0. which scenarios are mine ──────────────────────────────────────────────
# One line per selected scenario, sorted, so every worker computes the same
# list from the same file and no worker needs to be told which slice is its
# own. Fields: leaf, token, handoff frame, data root, recipe-or-'-',
# nurec work dir-or-'-'.
mapfile -t ALL_ROWS < <(python3 - "$SELECTION" <<'PY'
import json, sys
sel = json.load(open(sys.argv[1]))
default = ",".join(a["id"] for a in sel["grid"]["arms"])
rows = []
for leaf, block in sel["leaves"].items():
    for p in block["picked"]:
        # A scenario may name its OWN arm subset. A leaf whose geometry cannot
        # take the full grid -- C-8 is backing, where the ego sits against the
        # kerb and 1.5 m to its right is the pavement -- would otherwise have
        # to be dropped or run with a single scenario. Absent, the full grid.
        rows.append("\t".join([
            leaf, p["token"], str(p["handoff"]), p["data_root"],
            p.get("recipe") or "-", p.get("nurec_work_dir") or "-",
            ",".join(p["arms_run"]) if p.get("arms_run") else default,
            str(p["ego_frames"])]))
print("\n".join(sorted(rows)))
PY
)
[ ${#ALL_ROWS[@]} -gt 0 ] || { say "no scenarios in $SELECTION"; exit 1; }
MY_ROWS=()
for i in "${!ALL_ROWS[@]}"; do
  [ $(( i % WORKERS )) -eq "$WORKER_INDEX" ] && MY_ROWS+=("${ALL_ROWS[$i]}")
done
say "scenarios ${#ALL_ROWS[@]} selected, ${#MY_ROWS[@]} mine"
[ ${#MY_ROWS[@]} -gt 0 ] || { say "nothing to do"; exit 0; }

# The perturbation grid travels in the same file as the selection it was
# screened against -- a grid and a screening that can disagree is a campaign
# that silently evaluates arms nobody checked.
mapfile -t ARMS < <(python3 - "$SELECTION" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1]))["grid"]["arms"]:
    print(f'{a["id"]}\t{a["lat"]}\t{a["lon"]}\t{a["yaw"]}')
PY
)
say "arms ${#ARMS[@]}: $(printf '%s\n' "${ARMS[@]}" | cut -f1 | tr '\n' ' ')"

mapfile -t ROWS < <(grep -v '^\s*#' "$MODELS_TSV" | grep -v '^\s*$')
say "models: $(printf '%s\n' "${ROWS[@]}" | cut -f1 | tr '\n' ' ')"
say "gpu: $GPU_LAYOUT, renderer --cache-size $RENDER_CACHE"

# ── 1. environment ───────────────────────────────────────────────────────────
# Verbatim from the rerun worker: the venv is built on the pod's own ephemeral
# /root every time, ~15 minutes, paid once per pod and amortised over ~250
# cells.
export DEBIAN_FRONTEND=noninteractive
say "apt: GL/X libs the renderer and IsaacSim need"
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

REPO=/root/ns
[ ! -e "$REPO" ] || { say "$REPO already exists; use a fresh worker pod"; exit 1; }
git clone --quiet --no-hardlinks /hugsim-storage/NexusSim "$REPO" || { say "clone FAILED"; exit 1; }
git -C "$REPO" checkout --quiet "$NEXUSSIM_SHA" || { say "checkout $NEXUSSIM_SHA FAILED"; exit 1; }
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
  uv pip install --python /root/ns-venv/bin/python lazy_loader einops >/dev/null
  uv pip install --python /root/ns-venv/bin/python ninja >/dev/null
fi
PY=/root/ns-venv/bin/python
"$PY" -c "import nexussim, isaaclab" || { say "venv unusable"; exit 1; }

# ── 1a. Omniverse Kit shader cache ───────────────────────────────────────────
# 7.6 of the ~10 minutes an IsaacSim boot costs is Kit compiling materials
# (omni.ujitso) and the ray-tracing pipeline, into a cache that dies with the
# pod. Restoring a warm tar takes AppLauncher from 467 s to 10.5 s. Compilation
# happens on an empty stage, before any scene is read, so one tar serves every
# scenario; it is keyed by DRIVER version because the OptiX/Vulkan pipeline
# caches are.
#
# EULA FIRST, and that ordering is the whole point. Locating the tar's
# destination needs `import isaacsim`, and that import without ACCEPT_EULA
# blocks on an interactive prompt and exits 1 -- so a script that exports the
# EULA vars AFTER this block restores nothing, says only "cannot locate the
# isaacsim package", and pays the eight minutes anyway. That is exactly what
# navsafe_eval/run_worker_current.sh does, which is why the production eval
# workers have never actually had this cache.
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES
KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d " ").tar
if [ -f "$KITCACHE" ]; then
  KITPKG=$("$PY" -c "import isaacsim, os; print(os.path.dirname(isaacsim.__file__))" 2>/dev/null)
  if [ -n "$KITPKG" ] && tar -xf "$KITCACHE" -C "$KITPKG" kit && tar -xf "$KITCACHE" -C / var root; then
    say "Kit shader cache restored into $KITPKG"
  else
    say "Kit cache restore FAILED — the first IsaacSim boot recompiles (~8 min)"
  fi
else
  say "no Kit cache at $KITCACHE — first boot recompiles (~8 min)"
fi
git -C "$REPO" checkout -- uv.lock 2>/dev/null || true
export PATH=/root/ns-venv/bin:$PATH
INC=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
[ -f "$INC/Python.h" ] || { say "missing Python.h"; exit 1; }
say "venv ready ($(git -C "$REPO" status --porcelain | wc -l) tracked files modified)"

# ── 1b. VLA venv (recogdrive_rl) ─────────────────────────────────────────────
# recogdrive and simwam run their models in a persistent subprocess under the
# shared vla venv built from the proven lockfile. resworld was NOT here: it has
# its own py3.8 venv on the PVC and resworld.py defaults to it, which is why
# swapping resworld for simwam means adding simwam to this list -- without it
# the venv is never built, NAVSAFE_VLA_PYTHON keeps its /bigdata default, and
# the adapter dies on a missing interpreter before it ever reaches the GPU.
# Every slug here must be listed EXACTLY. `simwam\b` does not match
# `simwam_base`: an underscore is a word character, so there is no word
# boundary between them, and a slug that slips past this test gets no venv
# at all -- NAVSAFE_VLA_PYTHON keeps its /bigdata default and the adapter
# dies on a missing interpreter before it ever reaches a GPU.
if grep -qE '^(recogdrive_il|recogdrive_rl|mtdrive_sft|mtdrive_mtgrpo|autovla|drivelaw|simwam|simwam_base|drivevla_w0)\b' "$MODELS_TSV"; then
  VLA_LOCK=/avl-west/navsafe_eval/env_kit/vla_requirements.lock.txt
  VLA_EXTRA_LOCK=/avl-west/navsafe_eval/env_kit/vla_extra_site_requirements.lock.txt
  [ -f "$VLA_LOCK" ] || { say "VLA lockfile missing at $VLA_LOCK"; exit 1; }
  if [ ! -x /root/vla-venv/bin/python ]; then
    say "building vla-venv (torch 2.10.0+cu128 + transformers 4.57.6, ~5 min)"
    uv venv --python 3.12 /root/vla-venv >/dev/null || { say "vla-venv create FAILED"; exit 1; }
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
  # Three packages the shared lockfile does not carry, because no earlier VLA
  # row needed them: tiktoken/blobfile are what Emu3Tokenizer imports, and
  # scipy is required by the FAST action tokenizer's remote code (transformers
  # refuses to load that module without it). Installed into vla-venv rather
  # than a side site-dir -- unlike DriveLaW's nuplan devkit these are ordinary
  # leaf packages and cannot shadow another row's torch/numpy.
  /root/vla-venv/bin/python -c 'import tiktoken, scipy' 2>/dev/null || \
    uv pip install --python /root/vla-venv/bin/python tiktoken blobfile scipy \
      || { say "drivevla_w0 deps FAILED"; exit 1; }
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
  [ -f /avl-west/navsafe_eval/model_zoo/drivelaw/inference_front.yaml ] || { say "missing DriveLaW config"; exit 1; }
fi

# ── 1c. ResWorld venv ─────────────────────────────────────────────────────────
# ResWorld is a nuScenes/mmdet3d model, not a navsim one: py3.8 + torch
# 1.9.1+cu111 + mmcv-full 1.4.0 + a source-built mmdet3d 0.17.1 with CUDA ops.
# None of that can share vla-venv (py3.12 / torch 2.10), so it gets its own,
# and unlike vla-venv this one lives on the PVC — the mmdet3d compile is ~10
# minutes and there is no reason for every worker to repeat it.
#
# Two fixes are baked into that PVC copy rather than installed here, because
# both are edits to third-party source: mmdet3d 0.17's
# `from numba.errors import NumbaPerformanceWarning` (the alias numba dropped
# in 0.49, so it fails against the pinned 0.53), and the pandas/lyft-sdk deps
# mmdet3d imports unconditionally.
if grep -q '^resworld\b' "$MODELS_TSV"; then
  RW_VENV=/avl-west/navsafe_eval/vla_repos/resworld-venv
  # `test -x` is not enough and was not enough: the first build of this venv
  # pointed bin/python at a uv-managed interpreter under /root, which is the
  # POD's ephemeral disk. The symlink survives on the PVC, its target does
  # not, so `-x` fails on a venv that looks perfectly intact — and would fail
  # identically on every fresh worker. The venv is rebuilt --relocatable with
  # its interpreter beside it under vla_repos/resworld-python; the check that
  # actually means something is whether it can import the stack.
  "$RW_VENV/bin/python" -c 'import torch, mmcv, mmdet3d' 2>/dev/null || {
    say "ResWorld venv at $RW_VENV cannot import torch/mmcv/mmdet3d"
    say "  (if bin/python is a dangling symlink, its interpreter was on a dead pod's disk)"
    ls -l "$RW_VENV/bin/python" 2>&1 | while read -r l; do say "  $l"; done
    exit 1
  }
  export NAVSAFE_RESWORLD_PYTHON="$RW_VENV/bin/python"
  say "ResWorld venv OK ($RW_VENV)"
fi

# ── 2. the renderer ──────────────────────────────────────────────────────────
# --artifact-glob covers only THIS worker's scenarios; pointing every worker at
# all 500 reconstructions would make each scan half a terabyte of CephFS to
# serve a handful of scenes.
SHARD=/root/shard
mkdir -p "$SHARD"
MY_SCENES=()
for ROW in "${MY_ROWS[@]}"; do
  IFS=$'\t' read -r _L T _H _DR _RC _WD _AR _EF <<< "$ROW"
  for f in /avl-west/navsafe_eval/dataset/"$T"/*.usdz \
           /avl-west/navsafe_dev/full_test_mirror/"$T"/*.usdz; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ -e "$SHARD/$b" ] && continue
    ln -sf "$f" "$SHARD/$b"; MY_SCENES+=("${b%.usdz}")
  done
done
mkdir -p "$HARMONIZER_CACHE"
say "shard holds ${#MY_SCENES[@]} reconstructions"

SERVE_PID=""
# A killed /app/run leaves its children alive, and an orphaned renderer holds
# ~19 GB that the replacement then cannot get -- every subsequent cell OOMs.
# Kill the tree and wait for the port to actually free.
stop_serve() {
  [ -n "$SERVE_PID" ] || return 0
  pkill -TERM -P "$SERVE_PID" 2>/dev/null
  kill -TERM "$SERVE_PID" 2>/dev/null
  sleep 5
  pkill -KILL -P "$SERVE_PID" 2>/dev/null
  kill -KILL "$SERVE_PID" 2>/dev/null
  pkill -KILL -f 'serve-grpc' 2>/dev/null
  for _ in $(seq 1 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || break
    exec 3<&- 3>&-; sleep 2
  done
  SERVE_PID=""
}

start_serve() {
  say "serve-grpc starting on GPU 0 (${GPU_LAYOUT}, --cache-size $RENDER_CACHE)"
  CUDA_VISIBLE_DEVICES=0 /app/run serve-grpc --host 0.0.0.0 \
    --enable-editing-actors --renderer default --cache-size "$RENDER_CACHE" \
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
  # the harmonizer weights and binds the port ~2 min later.
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

trap 'say "exiting"; tail -40 /tmp/serve.log 2>/dev/null; stop_serve' EXIT
start_serve || exit 1

# ── 3. the sweep ─────────────────────────────────────────────────────────────
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=$PORT
# RECON rig: the reconstruction's own training CameraSpec and baked cam->rig,
# preserving calibrated distortion, native extent and observed rays. This is
# the default since 2026-08-31 and the rig every current NavSafe number uses;
# it is named here so the campaign records which one it ran.
export NUREC_GRPC_CAM_RIG=${NUREC_GRPC_CAM_RIG:-recon} NUREC_GRPC_TIMEOUT_S=600
export PY123D_RECENTER=1
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NEXUSSIM_NO_CAM_MAP_LINES=1
export PYTHONPATH="$REPO:$REPO/third_party/nurec_protos"
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES UV_NO_SYNC=1
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
# The rollout and any VLA subprocess server go on the LAST visible card, which
# is the renderer's own card in a one-GPU pod and a card of their own in a
# two-GPU one. NAVSAFE_VLA_GPU otherwise defaults to 7, an index no pod here has.
export CUDA_VISIBLE_DEVICES=$EVAL_GPU NEXUSSIM_NUREC_GPUS=1
export NAVSAFE_VLA_GPU=${NAVSAFE_VLA_GPU:-$EVAL_GPU}

done_n=0; skip_n=0; fail_n=0; consec_fail=0

gpu_is_gone() {
  grep -qE "cudaErrorInitializationError|CUDA driver initialization failed|no CUDA-capable device|CUDA unknown error" "$1"
}

for ROW in "${MY_ROWS[@]}"; do
  IFS=$'\t' read -r LEAF T HANDOFF DATA_ROOT RECIPE WORKDIR ARM_IDS EGO_FRAMES <<< "$ROW"
  B=/avl-west/navsafe_eval/dataset/$T
  [ -d "$B" ] || B=/avl-west/navsafe_dev/full_test_mirror/$T
  HANDOFF_ARG=$("$PY" -m nexussim.navsafe.eval.bundle --handoff "$B" 2>/dev/null)
  [ -n "$HANDOFF_ARG" ] || { say "$T: no handoff, skipping scenario"; fail_n=$((fail_n+1)); continue; }
  export NUREC_GRPC_HANDOFF="$HANDOFF_ARG"

  WORKDIR_ARGS=()
  [ "$WORKDIR" != "-" ] && WORKDIR_ARGS=(--nurec-work-dir "$WORKDIR")
  # The asset-harvester bank sits beside the RECONSTRUCTIONS, which for an
  # edited scenario is the corpus _20s dir and not the published bundle. Pass
  # the manifest PATH, never the bare flag: with no value the eval resolves the
  # bank from --py123d-data-root's parent and ap.error()s on a path that was
  # never going to exist, killing the cell at argument parsing.
  AH=()
  AH_BASE="$B"
  [ "$WORKDIR" != "-" ] && AH_BASE="$WORKDIR/${T}_20s"
  _ahm="$AH_BASE/ah_assets/replace_manifest.json"
  [ -f "$_ahm" ] && AH=(--asset-harvester-replace "$_ahm")
  # The recipe is AUTO-SELECTED, exactly as in the rerun worker, rather than
  # named here. resolve_recipe (nexussim/navsafe/editing/autoselect.py) is what
  # decides, and its decision is not "is there a file": 28 of the 80 recipes
  # carry `actors: {}` -- all of C-10, all of V-11, and a few C-7/R-2/V-10 --
  # and for those it returns None and the scenario runs UNEDITED, keeping the
  # hand-off this flag asks for instead of the recipe's 8. Naming the recipe
  # with --recipe would override that and force a hand-off no placement needs.
  # It also switches --traffic-mode to navsafe by itself when, and only when,
  # there are actors to drive.
  # THE EPISODE ENDS WHERE THE LOG DOES. --eval-frames counts SCORED frames, so
  # the run lasts handoff + eval_frames; the rerun campaign's constant 600 makes
  # that 620 on a scenario whose log is 201 frames long, and the ego then drives
  # for 40 s through a world with no data in it -- agents frozen at their last
  # pose, and the four 5 s reconstructions long since out of range. Measured
  # here on 190c8d0cece45af1: at frame 220 the ego was still doing 8.7 m/s past
  # the end of a 201-frame log. That was invisible in the rerun sweep because
  # without --enable-vis a frame costs ~1.2 s and 620 of them fit inside the
  # 45 min cell timeout; at 4.35 s/frame with four cameras they do not, so the
  # constant would also have killed every cell at the timeout.
  #
  # Scenario-specific, and identical across the arms of one scenario, so two
  # arms differ in where the ego went and not in how long it was allowed to go.
  EVAL_FRAMES=$(( EGO_FRAMES - HANDOFF - 1 ))
  [ "$EVAL_FRAMES" -ge 20 ] || EVAL_FRAMES=20
  say "$T ($LEAF): handoff=$HANDOFF log=$EGO_FRAMES frames -> --eval-frames $EVAL_FRAMES"
  say "$T ($LEAF): handoff=$HANDOFF data_root=$DATA_ROOT recipe=$([ "$RECIPE" = "-" ] && echo none || basename "$RECIPE") arms=$ARM_IDS"

  for ARM in "${ARMS[@]}"; do
    IFS=$'\t' read -r AID ALAT ALON AYAW <<< "$ARM"
    # Only the arms this scenario was screened for (see the selection reader).
    case ",$ARM_IDS," in *",$AID,"*) ;; *) continue ;; esac
    for MROW in "${ROWS[@]}"; do
      IFS=$'\t' read -r SLUG MT CK EXTRA_ENV <<< "$MROW"
      case "$CK" in
        none) CKPT=none ;;
        /*)   CKPT="$CK" ;;
        *)    CKPT="$ZOO/$CK" ;;
      esac
      unset NAVSAFE_RECOGDRIVE_VLM NAVSAFE_AUTOVLA_BASE NAVSAFE_AUTOVLA_REPO \
            NAVSAFE_DRIVELAW_REPO NAVSAFE_SIMWAM_REPO NAVSAFE_RESWORLD_REPO \
            NAVSAFE_PRIOREYE_EMBEDDING
      if [ -n "${EXTRA_ENV:-}" ]; then
        IFS=',' read -ra _KVS <<< "$EXTRA_ENV"
        for _KV in "${_KVS[@]}"; do export "${_KV?}"; done
      fi

      for SEED in $SEEDS; do
        OUT="$OUTROOT/seed$SEED/$LEAF/$T/$AID/$SLUG"
        LOG="$OUT.log"
        mkdir -p "$(dirname "$LOG")"
        # A cell is done when eval_py123d said so AND the two artifacts this
        # campaign exists for are on disk. plan_records.json is checked as well
        # as navsafe_metrics.json: a run that scored but wrote no plan record
        # is useless here and must be redone, not skipped.
        if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" \
           && [ -f "$OUT/navsafe_metrics.json" ] && [ -f "$OUT/plan_records.json" ]; then
          skip_n=$((skip_n+1)); continue
        fi
        serve_alive || { say "renderer died — restarting"; stop_serve; start_serve || exit 1; }

        mkdir -p "$OUT"
        say "  $T $AID $SLUG seed$SEED"
        cell_ok=0
        for _try in $(seq 1 "${CELL_TRIES:-3}"); do
          [ "$_try" -gt 1 ] && {
            say "    retry $_try/${CELL_TRIES:-3} after transient failure"
            sleep 30
            serve_alive || { say "    renderer gone — restarting"; stop_serve; start_serve || exit 1; }
          }
          timeout --signal=KILL "$CELL_TIMEOUT" \
            "$PY" "$REPO/scripts/tools/eval_py123d.py" \
              --scenario-source py123d --py123d-data-root "$DATA_ROOT" --py123d-scene-index 0 \
              "${WORKDIR_ARGS[@]}" \
              --render-backend nurec_grpc --cam-height navsim \
              --model-type "$MT" --checkpoint "$CKPT" \
              --traffic-mode semi_reactive \
              --recipe-dir "$REPO/nexussim/navsafe/recipes/benchmark" \
              "${AH[@]}" \
              --ego-replay-frames "$HANDOFF" \
              --ego-perturb-lateral "$ALAT" \
              --ego-perturb-longitudinal "$ALON" \
              --ego-perturb-yaw "$AYAW" \
              --terminate-on-collision \
              --controller lqr --execution-mode controller \
              --replan-rate 5 --camera-resolution-scale 1.0 \
              --eval-frames "$EVAL_FRAMES" \
              --eval-seed "$SEED" \
              --enable-vis --vis-cameras CAM_L0,CAM_R0,CAM_B0 \
              --output-dir "$OUT" > "$LOG" 2>&1
          if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && [ -f "$OUT/navsafe_metrics.json" ]; then
            cell_ok=1; break
          fi
          gpu_is_gone "$LOG" && say "    CUDA init failed (error 999)"
        done
        if [ "$cell_ok" != 1 ] && gpu_is_gone "$LOG"; then
          say "GPU UNUSABLE on $(hostname) after ${CELL_TRIES:-3} tries — failing so the Job reschedules"
          exit 1
        fi
        if [ "$cell_ok" = 1 ]; then
          done_n=$((done_n+1)); consec_fail=0
        else
          # One arm/model failing is not the scenario's fault -- a different
          # arm of the same scenario may well be fine, and dropping the whole
          # token would take 94 good cells with it. Record and move on.
          fail_n=$((fail_n+1)); consec_fail=$((consec_fail+1))
          say "    FAILED after ${CELL_TRIES:-3} tries (see $LOG)"
          tail -5 /tmp/serve.log > "$OUT.serve.log" 2>/dev/null
          if [ "$consec_fail" -ge 20 ]; then
            say "ABORT: $consec_fail consecutive failures — this node looks unusable"
            exit 1
          fi
        fi
      done
    done
  done
done

say "WORKER DONE ok=$done_n skipped=$skip_n failed=$fail_n"
[ "$fail_n" -eq 0 ]
