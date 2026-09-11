#!/usr/bin/env bash
set -euo pipefail
: "${INPUT_ROOT:?}" "${JOB_COMPLETION_INDEX:?}"
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES
W="w${JOB_COMPLETION_INDEX}"
OUTROOT="$INPUT_ROOT/results"
mkdir -p "$OUTROOT/$W"
exec > >(tee -a "$OUTROOT/$W/worker.log") 2>&1
say(){ echo "[$W $(date -u +%H:%M:%S)] $*"; }
# Each indexed worker runs one scene's three events; no ego perturbation.
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
mkdir -p "$REPO"
tar -xzf "$INPUT_ROOT/runtime.tar.gz" -C "$REPO"
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

export PATH=/root/ns-venv/bin:$PATH
INC=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
[ -f "$INC/Python.h" ] || { say "missing Python.h"; exit 1; }
say "venv ready from frozen runtime snapshot"


export PYTHONPATH="$REPO:$REPO/third_party/nurec_protos"
export NAVSAFE_ASSET_BANK=/avl-west/navsafe_eval/asset NAVSAFE_GAIT_BANK=/avl-west/navsafe_eval/gait_bank
export PY123D_RECENTER=1 NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=8080 NUREC_GRPC_CAM_RIG=recon NUREC_GRPC_TIMEOUT_S=600
export NEXUSSIM_NO_CAM_MAP_LINES=1 NEXUSSIM_NO_OVERLAY=0 UV_NO_SYNC=1
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
export NAVSAFE_VLA_GPU=0 NEXUSSIM_NUREC_GPUS=1
"$PY" "$INPUT_ROOT/check_inputs.py"
mapfile -t CELLS < <("$PY" - "$INPUT_ROOT/cells.json" "$JOB_COMPLETION_INDEX" <<'PYCELLS'
import json,sys
rows=json.load(open(sys.argv[1]));token=sorted({r['token'] for r in rows})[int(sys.argv[2])]
for r in rows:
 if r['token']==token: print('	'.join(str(r[k]) for k in ['leaf','token','event','recipe','data_root','replay_frames']))
PYCELLS
)
[ "${#CELLS[@]}" -eq 3 ]
IFS=$'\t' read -r _ TOKEN _ _ DATA_ROOT _ <<< "${CELLS[0]}"
B="$(dirname "$DATA_ROOT")"
export NUREC_GRPC_HANDOFF
NUREC_GRPC_HANDOFF=$("$PY" -m nexussim.navsafe.eval.bundle --handoff "$B")
mkdir -p /root/shard
for f in "$B"/*.usdz; do test -f "$f"; ln -s "$f" /root/shard/; done
# A dedicated renderer per worker avoids cross-job actor state contamination.
CUDA_VISIBLE_DEVICES=0 /app/run serve-grpc --host 0.0.0.0 --enable-editing-actors  --renderer default --cache-size 4 --enable-harmonizer  --harmonizer-cache /avl-west/navsafe_dev/.harmonizer-cache  --artifact-glob '/root/shard/*.usdz' > "$OUTROOT/$W/renderer.log" 2>&1 &
SERVE_PID=$!
# Only terminate this script's own renderer on Job exit.
trap 'kill "$SERVE_PID" 2>/dev/null || true' EXIT
ready=0
for ((i=0;i<240;i++)); do
 kill -0 "$SERVE_PID" || { tail -50 "$OUTROOT/$W/renderer.log"; exit 1; }
 if grep -q 'Serving on' "$OUTROOT/$W/renderer.log"; then ready=1; break; fi
 sleep 5
done
[ "$ready" -eq 1 ]
for f in "$B"/*.usdz; do grep 'Available scenes' "$OUTROOT/$W/renderer.log" | grep -Fq "$(basename "$f" .usdz)"; done
fail=0
for row in "${CELLS[@]}"; do
 IFS=$'\t' read -r LEAF TOKEN EVENT RECIPE DATA_ROOT HANDOFF <<< "$row"
 OUT="$OUTROOT/$LEAF/$TOKEN/$EVENT/drivor"; mkdir -p "$OUT"
 say "Starting $LEAF $EVENT: DrivoR, scored cap 200, replay $HANDOFF, vis ON"
 # Preserve exit status: DONE alone is not enough to call a run successful.
 if CUDA_VISIBLE_DEVICES=1 timeout --signal=TERM --kill-after=30s 45m   "$PY" "$REPO/scripts/tools/eval_py123d.py"   --scenario-source py123d --py123d-data-root "$DATA_ROOT" --py123d-scene-index 0   --render-backend nurec_grpc --cam-height navsim   --model-type drivor --checkpoint /avl-west/navsafe_eval/model_zoo/drivor/drivor_Nav1_25epochs.pth   --traffic-mode navsafe --recipe "$RECIPE" --ego-replay-frames "$HANDOFF"   --terminate-on-collision --controller lqr --execution-mode controller   --replan-rate 5 --camera-resolution-scale 1.0 --eval-frames 200 --eval-seed 0   --enable-vis --vis-cameras CAM_L0,CAM_R0,CAM_B0 --output-dir "$OUT" > "$OUT/eval.log" 2>&1; then rc=0; else rc=$?; fi
 echo "$rc" > "$OUT/exit_code.txt"
 if [ "$rc" -ne 0 ] || ! grep -q '^\[eval_py123d\] DONE\.' "$OUT/eval.log" || [ ! -s "$OUT/navsafe_metrics.json" ] || [ ! -s "$OUT/plan_records.json" ]; then
  fail=$((fail+1)); say "FAILED $EVENT (exit $rc)"; tail -30 "$OUT/eval.log"
 else say "Completed $EVENT"; fi
 "$PY" "$INPUT_ROOT/summarize.py" "$OUTROOT" "$OUTROOT/$W/summary.json"
done
"$PY" - "$OUTROOT/$W/summary.json" "$TOKEN" <<'PYSUMMARY'
import json,sys
rows=[r for r in json.load(open(sys.argv[1])) if r['token']==sys.argv[2]]
assert len(rows)==3 and all(r['status']=='passed' for r in rows), rows
PYSUMMARY
[ "$fail" -eq 0 ]
