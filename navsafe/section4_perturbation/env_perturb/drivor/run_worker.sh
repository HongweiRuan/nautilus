#!/usr/bin/env bash
set -uo pipefail
: "${INPUT_ROOT:?}" "${MODEL_TSV:?}" "${JOB_COMPLETION_INDEX:?}"
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES
W=$(printf 'w%02d' "$JOB_COMPLETION_INDEX")
MODEL=$(cut -f1 "$MODEL_TSV")
OUTROOT=${OUTROOT:-/avl-west/navsafe_eval/proxy_set_state_perturbation_outputs}
WLOG="$OUTROOT/$MODEL/workers/$W.log"
mkdir -p "$(dirname "$WLOG")"
exec > >(tee -a "$WLOG") 2>&1
say(){ echo "[$W $(date -u +%H:%M:%S)] $*"; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq git curl python3-venv python3-dev \
  libglu1-mesa libxt6 libgl1 libglx0 libegl1 libglib2.0-0 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxext6 libxrender1 libx11-6 libxfixes3 libxdamage1 libsm6 \
  libice6 libgomp1 >/dev/null || exit 1
export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
export UV_CACHE_DIR=/root/.cache/uv UV_PROJECT_ENVIRONMENT=/root/ns-venv
for i in 1 2 3 4; do
  command -v uv >/dev/null && break
  python -m pip install --quiet --user uv 2>/dev/null || pip install --quiet --user uv 2>/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
  hash -r; sleep 5
done
command -v uv >/dev/null || { say "uv unavailable"; exit 1; }

REPO=/root/ns
RECIPE_ROOT=${RECIPE_ROOT:-/hugsim-storage/NexusSim/nexussim/navsafe/recipes/proxy_set_state_perturbation}
[ ! -e "$REPO" ] || { say "$REPO already exists"; exit 1; }
mkdir -p "$REPO"
tar -xzf "$RUNTIME_TAR" -C "$REPO"
cd "$REPO"
git apply --check "$RUNTIME_PATCH" && git apply "$RUNTIME_PATCH" || { say "takeover runtime patch failed"; exit 1; }
if ! /root/ns-venv/bin/python -c 'import isaacsim, isaaclab, nexussim' 2>/dev/null; then
  uv sync --all-extras --python 3.12 || exit 1
  [ -d /root/IsaacLab/.git ] || git clone --depth 1 --branch v3.0.0-beta https://github.com/isaac-sim/IsaacLab.git /root/IsaacLab
  for ext in isaaclab isaaclab_assets isaaclab_tasks isaaclab_rl isaaclab_mimic; do
    d=/root/IsaacLab/source/$ext; [ -d "$d" ] && uv pip install --python /root/ns-venv/bin/python --no-deps -e "$d" >/dev/null
  done
  uv pip install --python /root/ns-venv/bin/python lazy_loader einops ninja >/dev/null
fi
PY=/root/ns-venv/bin/python
export PATH=/root/ns-venv/bin:$PATH
INC=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
[ -f "$INC/Python.h" ] || { say "missing Python.h"; exit 1; }

IFS=$'\t' read -r SLUG MT CK EXTRA_ENV < "$MODEL_TSV"
case "$CK" in none) CKPT=none;; /*) CKPT="$CK";; *) CKPT="/avl-west/navsafe_eval/model_zoo/$CK";; esac
if [ -n "${EXTRA_ENV:-}" ]; then IFS=',' read -ra KVS <<< "$EXTRA_ENV"; for KV in "${KVS[@]}"; do export "$KV"; done; fi
if [[ "$SLUG" =~ ^(recogdrive_il|recogdrive_rl|mtdrive_sft|mtdrive_mtgrpo|autovla|drivelaw|simwam|simwam_base|drivevla_w0)$ ]]; then
  VLA_LOCK=/avl-west/navsafe_eval/env_kit/vla_requirements.lock.txt
  VLA_EXTRA=/avl-west/navsafe_eval/env_kit/vla_extra_site_requirements.lock.txt
  uv venv --python 3.12 /root/vla-venv >/dev/null
  grep -v '^omegaconf==' "$VLA_LOCK" > /tmp/vla_reqs.txt
  uv pip install --python /root/vla-venv/bin/python --extra-index-url https://download.pytorch.org/whl/cu128 --index-strategy unsafe-best-match -r /tmp/vla_reqs.txt
  uv pip install --python /root/vla-venv/bin/python --no-deps omegaconf==2.4.0.dev14
  export NAVSAFE_VLA_PYTHON=/root/vla-venv/bin/python
  if [ "$SLUG" = drivevla_w0 ]; then uv pip install --python /root/vla-venv/bin/python tiktoken blobfile scipy; fi
  if [ "$SLUG" = drivelaw ]; then mkdir -p /root/vla_extra_site; uv pip install --target /root/vla_extra_site --no-deps -r "$VLA_EXTRA"; export NAVSAFE_VLA_EXTRA_PYTHONPATH=/root/vla_extra_site; fi
fi

mapfile -t CELLS < <("$PY" - "$CELLS_JSON" "$JOB_COMPLETION_INDEX" <<'PYROWS'
import json,sys
rows=json.load(open(sys.argv[1])); requested=[t for t in __import__('os').environ.get('RUN_TOKENS','').split(',') if t]; tokens=requested or sorted({r['token'] for r in rows}); token=tokens[int(sys.argv[2])]
for r in rows:
 if r['token']==token: print('\t'.join(str(r.get(k) or '-') for k in ['leaf','token','event','recipe','data_root','asset_harvester_manifest','replay_frames']))
PYROWS
)
[ "${#CELLS[@]}" -eq 2 ] || { say "index must own exactly two events"; exit 1; }
IFS=$'\t' read -r LEAF TOKEN _ _ DATA_ROOT _ _ <<< "${CELLS[0]}"
B=$(dirname "$DATA_ROOT")
export NUREC_GRPC_HANDOFF
NUREC_GRPC_HANDOFF=$("$PY" -m nexussim.navsafe.eval.bundle --handoff "$B")

mkdir -p /root/shard
SCENES=()
for f in "$B"/*.usdz; do [ -f "$f" ] || continue; ln -s "$f" /root/shard/; SCENES+=("$(basename "$f" .usdz)"); done
[ "${#SCENES[@]}" -gt 0 ] || { say "no reconstruction for $TOKEN"; exit 1; }
N_GPU=$(nvidia-smi -L | grep -c '^GPU '); EVAL_GPU=$((N_GPU-1))
KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ').tar
if [ -f "$KITCACHE" ]; then KITPKG=$("$PY" -c 'import isaacsim,os; print(os.path.dirname(isaacsim.__file__))'); tar -xf "$KITCACHE" -C "$KITPKG" kit; tar -xf "$KITCACHE" -C / var root; fi

export PYTHONPATH="$REPO:$REPO/third_party/nurec_protos" NAVSAFE_ASSET_BANK=/avl-west/navsafe_eval/asset NAVSAFE_GAIT_BANK=/avl-west/navsafe_eval/gait_bank
export PY123D_RECENTER=1 NUPLAN_MAP_VERSION=nuplan-maps-v1.0 NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=8080 NUREC_GRPC_CAM_RIG=recon NUREC_GRPC_TIMEOUT_S=600
export NEXUSSIM_NO_CAM_MAP_LINES=1 NEXUSSIM_NO_OVERLAY=0 UV_NO_SYNC=1 LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6 NEXUSSIM_NUREC_GPUS=1 NAVSAFE_INSERT_CLASS_PER_SCENE=1
export NAVSAFE_VLA_GPU=$EVAL_GPU
CUDA_VISIBLE_DEVICES=0 /app/run serve-grpc --host 0.0.0.0 --enable-editing-actors --renderer default --cache-size 4 --enable-harmonizer --harmonizer-cache /avl-west/navsafe_dev/.harmonizer-cache --artifact-glob '/root/shard/*.usdz' > /tmp/renderer.log 2>&1 &
SERVE_PID=$!
cleanup(){ kill -TERM "$SERVE_PID" 2>/dev/null || true; pkill -TERM -P "$SERVE_PID" 2>/dev/null || true; }
trap cleanup EXIT
for i in $(seq 1 240); do kill -0 "$SERVE_PID" || { tail -60 /tmp/renderer.log; exit 1; }; grep -q 'Serving on' /tmp/renderer.log && break; sleep 5; done
grep -q 'Serving on' /tmp/renderer.log || { tail -60 /tmp/renderer.log; exit 1; }
for S in "${SCENES[@]}"; do grep 'Available scenes' /tmp/renderer.log | grep -Fq "$S" || { say "renderer missing $S"; exit 1; }; done

failed=0
for ROW in "${CELLS[@]}"; do
  IFS=$'\t' read -r LEAF TOKEN EVENT RECIPE DATA_ROOT AH HANDOFF <<< "$ROW"
  OUT="$OUTROOT/$MODEL/$LEAF/$TOKEN/$EVENT"; LOG="$OUT/eval.log"; mkdir -p "$OUT"
  if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && [ -s "$OUT/navsafe_metrics.json" ] && [ -s "$OUT/plan_records.json" ]; then say "skip complete $LEAF/$EVENT"; continue; fi
  if [ -s "$LOG" ]; then
    mv "$LOG" "$OUT/eval.previous.$(date -u +%Y%m%dT%H%M%SZ).log"
  fi
  AH_ARGS=(); [ "$AH" != "-" ] && AH_ARGS=(--asset-harvester-replace "$AH")
  say "run $MODEL $LEAF $TOKEN $EVENT (600 scored frames, no per-cell timeout)"
  if CUDA_VISIBLE_DEVICES=$EVAL_GPU "$PY" "$REPO/scripts/tools/eval_py123d.py" \
      --scenario-source py123d --py123d-data-root "$DATA_ROOT" --py123d-scene-index 0 \
      --render-backend nurec_grpc --cam-height navsim --model-type "$MT" --checkpoint "$CKPT" \
      --traffic-mode navsafe --recipe "$RECIPE_ROOT/$RECIPE" \
      "${AH_ARGS[@]}" --ego-replay-frames "$HANDOFF" --terminate-on-collision \
      --controller lqr --execution-mode controller --replan-rate 5 --camera-resolution-scale 1.0 \
      --eval-frames 600 --eval-seed 0 --enable-vis --vis-cameras CAM_L0,CAM_R0,CAM_B0 \
      --output-dir "$OUT" > "$LOG" 2>&1; then rc=0; else rc=$?; fi
  echo "$rc" > "$OUT/exit_code.txt"
  ok=1
  grep -qs '^\[eval_py123d\] DONE\.' "$LOG" || ok=0
  [ -s "$OUT/navsafe_metrics.json" ] && [ -s "$OUT/plan_records.json" ] || ok=0
  [ "$AH" = "-" ] || [ -s "$OUT/harvester_takeover_audit.json" ] || ok=0
  if [ "$ok" = 1 ]; then
    say "complete $LEAF/$EVENT"
  else
    failed=$((failed+1))
    cp /tmp/renderer.log "$OUT/renderer.log" 2>/dev/null || true
    say "FAILED $LEAF/$EVENT rc=$rc"
    tail -30 "$LOG"
  fi
done
say "worker finished; failed=$failed"
[ "$failed" -eq 0 ]
