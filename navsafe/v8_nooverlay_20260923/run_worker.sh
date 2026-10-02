#!/usr/bin/env bash
set -euo pipefail
: "${JOB_COMPLETION_INDEX:?}" "${OUTROOT:?}" "${INPUT_ROOT:?}" "${RUNTIME_TAR:?}"
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES NEXUSSIM_NO_OVERLAY=1
export DEBIAN_FRONTEND=noninteractive
W=$(printf 'w%02d' "$JOB_COMPLETION_INDEX")
TOKEN=$(sed -n "$((JOB_COMPLETION_INDEX+1))p" /cfg/tokens.txt)
[ -n "$TOKEN" ] || { echo "no token for index $JOB_COMPLETION_INDEX"; exit 1; }
OUT="$OUTROOT/$TOKEN"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/worker.log") 2>&1
say(){ echo "[$W $(date -u +%H:%M:%S)] $*"; }
trap 'rc=$?; if [ -n "${SERVE_PID:-}" ]; then kill "$SERVE_PID" 2>/dev/null || true; fi; exit $rc' EXIT

say "token=$TOKEN; 200-frame pure ego replay; recipe; vis CAM_F0/CAM_L0/CAM_R0; no overlay"
test -s "$RUNTIME_TAR"
B="$INPUT_ROOT/$TOKEN"
RECIPE_GLOB="/root/ns/nexussim/navsafe/recipes/benchmark/V-8.$TOKEN.yaml"
test -d "$B/arrow"
set -- "$B"/*.usdz
[ "$#" -eq 4 ]
for f in "$@"; do [ -e "$f" ]; done

apt-get update -qq
apt-get install -y -qq git curl python3-venv python3-dev libglu1-mesa libxt6 libgl1 libglx0 libegl1 libglib2.0-0 libxrandr2 libxinerama1 libxcursor1 libxi6 libxext6 libxrender1 libx11-6 libxfixes3 libxdamage1 libsm6 libice6 libgomp1 >/dev/null
export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
export UV_CACHE_DIR=/avl-west/navsafe_dev/.uv-cache UV_PROJECT_ENVIRONMENT=/root/ns-venv VIRTUAL_ENV=/root/ns-venv
for i in 1 2 3 4; do
  command -v uv >/dev/null && break
  python -m pip install --quiet --user uv 2>/dev/null || pip install --quiet --user uv 2>/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
  hash -r; sleep 5
done
command -v uv >/dev/null
mkdir -p /root/ns
tar -xzf "$RUNTIME_TAR" -C /root/ns
cd /root/ns
if ! /root/ns-venv/bin/python -c 'import isaacsim, isaaclab, nexussim' 2>/dev/null; then
  say "uv sync"
  uv sync --all-extras --python 3.12
  [ -d /root/IsaacLab/.git ] || git clone --depth 1 --branch v3.0.0-beta https://github.com/isaac-sim/IsaacLab.git /root/IsaacLab
  for ext in isaaclab isaaclab_assets isaaclab_tasks isaaclab_rl isaaclab_mimic; do
    d=/root/IsaacLab/source/$ext
    [ -d "$d" ] && uv pip install --python /root/ns-venv/bin/python --no-deps -e "$d" >/dev/null
  done
  uv pip install --python /root/ns-venv/bin/python lazy_loader einops ninja >/dev/null
fi
PY=/root/ns-venv/bin/python
"$PY" -c 'import nexussim, isaaclab'
test -f "$RECIPE_GLOB"

KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ').tar
if [ -f "$KITCACHE" ]; then
  KITPKG=$("$PY" -c 'import isaacsim,os; print(os.path.dirname(isaacsim.__file__))')
  tar -xf "$KITCACHE" -C "$KITPKG" kit && tar -xf "$KITCACHE" -C / var root || true
fi

export PATH=/root/ns-venv/bin:$PATH
export PYTHONPATH=/root/ns:/root/ns/third_party/nurec_protos
export NAVSAFE_ASSET_BANK=/avl-west/navsafe_eval/asset NAVSAFE_ASSET_MOUNT=/avl-west/navsafe_eval/asset
export NAVSAFE_GAIT_BANK=/avl-west/navsafe_eval/gait_bank
export PY123D_RECENTER=1 NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=8080 NUREC_GRPC_CAM_RIG=recon NUREC_GRPC_TIMEOUT_S=600
export NEXUSSIM_NO_CAM_MAP_LINES=1 UV_NO_SYNC=1 LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6
export NEXUSSIM_NUREC_GPUS=1 NAVSAFE_VLA_GPU=1
export NUREC_GRPC_HANDOFF
NUREC_GRPC_HANDOFF=$("$PY" -m nexussim.navsafe.eval.bundle --handoff "$B")

mkdir -p /root/shard
for f in "$B"/*.usdz; do ln -s "$f" /root/shard/; done
say "starting renderer"
CUDA_VISIBLE_DEVICES=0 /app/run serve-grpc --host 0.0.0.0 --enable-editing-actors --renderer default --cache-size 4 --enable-harmonizer --harmonizer-cache /avl-west/navsafe_dev/.harmonizer-cache --artifact-glob '/root/shard/*.usdz' > "$OUT/renderer.log" 2>&1 &
SERVE_PID=$!
ready=0
for ((i=0;i<240;i++)); do
  kill -0 "$SERVE_PID" || { tail -80 "$OUT/renderer.log"; exit 1; }
  if grep -q 'Serving on' "$OUT/renderer.log"; then ready=1; break; fi
  sleep 5
done
[ "$ready" -eq 1 ]
for f in "$B"/*.usdz; do grep 'Available scenes' "$OUT/renderer.log" | grep -Fq "$(basename "$f" .usdz)"; done

cat > "$OUT/run_spec.json" <<EOF
{"token":"$TOKEN","recipe":"V-8.$TOKEN.yaml","ego_replay_frames":200,"eval_frames":0,"enable_vis":true,"vis_cameras":["CAM_F0","CAM_L0","CAM_R0"],"NEXUSSIM_NO_OVERLAY":"1"}
EOF
say "starting eval"
set +e
CUDA_VISIBLE_DEVICES=1 timeout --signal=TERM --kill-after=30s 90m \
  "$PY" /root/ns/scripts/tools/eval_py123d.py \
    --scenario-source py123d --py123d-data-root "$B/arrow" --py123d-scene-index 0 \
    --render-backend nurec_grpc --cam-height navsim \
    --model-type pdm_closed --checkpoint none \
    --traffic-mode navsafe --recipe "$RECIPE_GLOB" \
    --ego-replay-frames 200 --keep-ego-replay-frames --eval-frames 0 \
    --camera-resolution-scale 1.0 --eval-seed 0 \
    --enable-vis --vis-cameras CAM_F0,CAM_L0,CAM_R0 \
    --output-dir "$OUT" > "$OUT/eval.log" 2>&1
rc=$?
set -e
echo "$rc" > "$OUT/exit_code.txt"
[ "$rc" -eq 0 ] || { tail -100 "$OUT/eval.log"; exit "$rc"; }
grep -q '^\[eval_py123d\] DONE\.' "$OUT/eval.log"

F=$(find "$OUT" -name cam_f0.jpg -type f | wc -l)
L=$(find "$OUT" -name cam_l0.jpg -type f | wc -l)
R=$(find "$OUT" -name cam_r0.jpg -type f | wc -l)
"$PY" - "$OUT/validation.json" "$F" "$L" "$R" <<'PYV'
import json,sys
p,f,l,r=sys.argv[1],*map(int,sys.argv[2:])
data={'cam_f0_frames':f,'cam_l0_frames':l,'cam_r0_frames':r,'expected_frames':200,'valid':f==l==r==200}
open(p,'w').write(json.dumps(data,indent=2)+'\n')
assert data['valid'], data
PYV
say "DONE: F0=$F L0=$L R0=$R"
