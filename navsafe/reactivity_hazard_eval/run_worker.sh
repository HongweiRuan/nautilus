#!/usr/bin/env bash
set -uo pipefail
: "${JOB_COMPLETION_INDEX:?}" "${WORKERS:?}" "${CAMPAIGN_ROOT:?}" "${OUTROOT:?}"
export ACCEPT_EULA=Y OMNI_KIT_ACCEPT_EULA=YES
W=$(printf 'w%02d' "$JOB_COMPLETION_INDEX")
WLOG="$OUTROOT/workers/$W.log"
mkdir -p "$(dirname "$WLOG")"
exec > >(tee -a "$WLOG") 2>&1
say(){ echo "[$W $(date -u +%H:%M:%S)] $*"; }

ROOT=/avl-west/navsafe_eval
REPO=/root/ns
PY=/root/ns-venv/bin/python
CELLS_JSON="$CAMPAIGN_ROOT/cells.json"
MODELS_TSV="${MODELS_TSV_PATH:-$CAMPAIGN_ROOT/models.tsv}"
RECIPE_ROOT=/root/navsafe-recipes
ASSIGN_INDEX="$JOB_COMPLETION_INDEX"
ASSIGN_WORKERS="$WORKERS"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq git curl python3-venv python3-dev \
  libglu1-mesa libxt6 libgl1 libglx0 libegl1 libglib2.0-0 libxrandr2 libxinerama1 \
  libxcursor1 libxi6 libxext6 libxrender1 libx11-6 libxfixes3 libxdamage1 libsm6 \
  libice6 libgomp1 >/dev/null || { say 'apt failed'; exit 1; }
export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
export UV_CACHE_DIR=/root/.cache/uv UV_PROJECT_ENVIRONMENT=/root/ns-venv
for _ in 1 2 3 4; do
  command -v uv >/dev/null && break
  python -m pip install --quiet --user uv 2>/dev/null || pip install --quiet --user uv 2>/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
  hash -r
  sleep 5
done
command -v uv >/dev/null || { say 'uv unavailable'; exit 1; }

[ ! -e "$REPO" ] || { say "$REPO already exists"; exit 1; }
mkdir -p "$REPO"
tar -xzf "$CAMPAIGN_ROOT/runtime.tar.gz" -C "$REPO" || { say 'runtime extraction failed'; exit 1; }
mkdir -p "$RECIPE_ROOT"
tar -xzf "$CAMPAIGN_ROOT/recipes.tar.gz" -C "$RECIPE_ROOT" || { say 'recipe extraction failed'; exit 1; }
cd "$REPO"
git apply --check "$CAMPAIGN_ROOT/original_car_takeover.patch" && git apply "$CAMPAIGN_ROOT/original_car_takeover.patch" || { say 'takeover patch failed'; exit 1; }
cp "$CAMPAIGN_ROOT/gtrs_dense.py" "$REPO/nexussim/policy/sensor/gtrs_dense.py"
cp "$CAMPAIGN_ROOT/from_run.py" "$REPO/nexussim/navsafe/scoring/from_run.py"
cp "$CAMPAIGN_ROOT/reactivity_trace.py" "$REPO/nexussim/evaluation/reactivity_trace.py"
python - <<'PY'
from pathlib import Path
p=Path('/root/ns/nexussim/engine/registry.py'); s=p.read_text(); needle='    "nexussim.policy.sensor.gtrs_dense",'
if needle not in s:
    anchor='    "nexussim.policy.sensor.ltf",'
    if anchor not in s: raise SystemExit('registry anchor missing')
    s=s.replace(anchor,anchor+'\n'+needle)
    p.write_text(s)
PY

if ! "$PY" -c 'import isaacsim, isaaclab, nexussim' 2>/dev/null; then
  say 'building NexusSim venv'
  uv sync --all-extras --python 3.12 || exit 1
  [ -d /root/IsaacLab/.git ] || git clone --depth 1 --branch v3.0.0-beta https://github.com/isaac-sim/IsaacLab.git /root/IsaacLab
  for ext in isaaclab isaaclab_assets isaaclab_tasks isaaclab_rl isaaclab_mimic; do
    d=/root/IsaacLab/source/$ext
    [ -d "$d" ] && uv pip install --python "$PY" --no-deps -e "$d" >/dev/null
  done
  uv pip install --python "$PY" lazy_loader einops ninja rasterio==1.4.3 retry==0.9.2 >/dev/null
fi
export PATH=/root/ns-venv/bin:$PATH
INC=$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
[ -f "$INC/Python.h" ] || { say "missing Python.h under $INC"; exit 1; }

# Optional tail mode: each indexed worker receives exactly one unfinished
# model/scenario/event tuple.  This keeps the same canonical worker while
# allowing the campaign tail to use one two-GPU pod per remaining eval.
if [ -n "${WORK_ITEMS_JSON:-}" ]; then
  [ -f "$WORK_ITEMS_JSON" ] || { say "missing work-items manifest $WORK_ITEMS_JSON"; exit 1; }
  CELLS_JSON=/tmp/assigned-cell.json
  MODELS_TSV=/tmp/assigned-model.tsv
  "$PY" - "$WORK_ITEMS_JSON" "$JOB_COMPLETION_INDEX" "$CELLS_JSON" "$MODELS_TSV" <<'PY'
import json, sys
src, index, cells_path, models_path = sys.argv[1:]
rows = json.load(open(src))
index = int(index)
if not 0 <= index < len(rows):
    raise SystemExit(f"work item index {index} outside [0, {len(rows)})")
row = rows[index]
required = ["model_slug", "model_type", "checkpoint", "leaf", "token", "event", "recipe", "data_root", "replay_frames"]
missing = [key for key in required if key not in row]
if missing:
    raise SystemExit(f"work item {index} missing fields: {missing}")
json.dump([row], open(cells_path, "w"), indent=2)
model = [row["model_slug"], row["model_type"], row["checkpoint"], row.get("extra_env", "")]
open(models_path, "w").write("\t".join(str(x) for x in model) + "\n")
print(f"assigned work item {index}: {row['model_slug']} {row['leaf']}/{row['token']}/{row['event']}")
PY
  ASSIGN_INDEX=0
  ASSIGN_WORKERS=1
fi

if grep -qE '^(recogdrive_il|recogdrive_rl|mtdrive_sft|mtdrive_mtgrpo|autovla)\b' "$MODELS_TSV"; then
  VLA_LOCK=$ROOT/env_kit/vla_requirements.lock.txt
  [ -f "$VLA_LOCK" ] || { say "missing $VLA_LOCK"; exit 1; }
  uv venv --python 3.12 /root/vla-venv >/dev/null || exit 1
  grep -v '^omegaconf==' "$VLA_LOCK" > /tmp/vla_reqs.txt
  uv pip install --python /root/vla-venv/bin/python --extra-index-url https://download.pytorch.org/whl/cu128 --index-strategy unsafe-best-match -r /tmp/vla_reqs.txt || exit 1
  uv pip install --python /root/vla-venv/bin/python --no-deps omegaconf==2.4.0.dev14 || exit 1
  export NAVSAFE_VLA_PYTHON=/root/vla-venv/bin/python
fi

# RAP uses BEVFormer CUDA operators from the OpenMMLab stack.  Keep the
# compiled packages in a side directory so their transitive numpy/torch wheels
# cannot replace IsaacSim's pinned environment.  mmcv 2.1.0 is required by
# mmdet 3.x; build isolation must be disabled so setup can import this venv's
# torch while compiling the CUDA extension.
MM_SITE=
if grep -qE '^rap\b' "$MODELS_TSV"; then
  MM_SITE=/root/mm_site
  say 'building RAP mmcv/mmdet stack (about 30 min, once per worker)'
  mkdir -p "$MM_SITE"
  uv pip install --python "$PY" --target "$MM_SITE" \
    --no-build-isolation \
    --extra-index-url https://download.pytorch.org/whl/cu128 \
    --index-strategy unsafe-best-match \
    mmengine 'mmcv==2.1.0' 'mmdet>=3.0.0,<3.4' \
    || { say 'RAP mmcv stack build failed'; exit 1; }
  PYTHONPATH="$MM_SITE" "$PY" -c \
    'from mmcv.ops.multi_scale_deform_attn import MultiScaleDeformableAttention; import mmengine, mmdet' \
    || { say 'RAP mmcv stack import failed'; exit 1; }
  say 'RAP mmcv stack ready'
fi

SIMSCALE_ROOT=$ROOT/aug_zoo/SimScale/source
NUPLAN_ROOT=$ROOT/aug_zoo/SimScale/nuplan-devkit
[ "$(git -C "$NUPLAN_ROOT" rev-parse HEAD 2>/dev/null)" = ce3c323af01c0d7ec5672f7832ef53f9c679aab0 ] || { say 'nuPlan pin mismatch'; exit 1; }
export PYTHONPATH="$SIMSCALE_ROOT:$NUPLAN_ROOT:$REPO:$REPO/third_party/nurec_protos${MM_SITE:+:$MM_SITE}"
"$PY" -c 'from navsim.agents.gtrs_dense.hydra_model import HydraModel; from nexussim.policy.sensor.gtrs_dense import GTRSDenseAdapter' || { say 'GTRS imports failed'; exit 1; }

mapfile -t TOKENS < <("$PY" - "$CELLS_JSON" "$ASSIGN_INDEX" "$ASSIGN_WORKERS" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); tokens=sorted({x['token'] for x in rows}); i,n=map(int,sys.argv[2:])
for j,t in enumerate(tokens):
    if j%n==i: print(t)
PY
)
[ ${#TOKENS[@]} -gt 0 ] || { say 'no assigned scenarios'; exit 0; }
say "assigned ${#TOKENS[@]} scenario(s): ${TOKENS[*]}"

SHARD=/root/shard
mkdir -p "$SHARD"
SCENES=()
for T in "${TOKENS[@]}"; do
  B=$("$PY" - "$CELLS_JSON" "$T" <<'PY'
import json,os,sys
for r in json.load(open(sys.argv[1])):
    if r["token"] == sys.argv[2]:
        print(os.path.dirname(r["data_root"])); break
else: raise SystemExit(f"missing token {sys.argv[2]}")
PY
)
  for f in "$B"/*.usdz; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$SHARD/$(basename "$f")"
    SCENES+=("$(basename "$f" .usdz)")
  done
done
[ ${#SCENES[@]} -ge $((4*${#TOKENS[@]})) ] || { say 'incomplete reconstruction shard'; exit 1; }

DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | tr -d ' ')
KITCACHE=/avl-west/navsafe_dev/kitcache/kitcache-3090-$DRV.tar
if [ -f "$KITCACHE" ]; then
  KITPKG=$("$PY" -c 'import isaacsim,os; print(os.path.dirname(isaacsim.__file__))' 2>/dev/null)
  if [ -n "$KITPKG" ] && tar -xf "$KITCACHE" -C "$KITPKG" kit && tar -xf "$KITCACHE" -C / var root; then
    say "restored warm Kit cache $KITCACHE"
  else
    say 'WARNING: warm Kit cache restore failed'
  fi
else
  say "WARNING: warm Kit cache missing for driver $DRV"
fi

export NAVSAFE_ASSET_BANK=$ROOT/asset NAVSAFE_GAIT_BANK=$ROOT/gait_bank
export PY123D_RECENTER=1 NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NUREC_GRPC_HOST=127.0.0.1 NUREC_GRPC_PORT=8080 NUREC_GRPC_CAM_RIG=recon NUREC_GRPC_TIMEOUT_S=600
export NEXUSSIM_NO_CAM_MAP_LINES=1 NEXUSSIM_NO_OVERLAY=0 UV_NO_SYNC=1
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6 NEXUSSIM_NUREC_GPUS=1 NAVSAFE_INSERT_CLASS_PER_SCENE=1
export NAVSAFE_VLA_GPU=1
mkdir -p /avl-west/navsafe_dev/.harmonizer-cache
SERVE_PID=
stop_renderer(){
  if [ -n "${SERVE_PID:-}" ]; then
    # /app/run is a shell wrapper around pycena.  Killing only the wrapper
    # reparents pycena to PID 1, leaving the real renderer on the GPU and port
    # 8080.  Each renderer owns a separate process group, so terminate the
    # whole tree atomically and escalate only if it ignores the grace period.
    kill -TERM -- "-$SERVE_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 -- "-$SERVE_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL -- "-$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
    SERVE_PID=
  fi
}
start_renderer(){
  stop_renderer
  : > /tmp/renderer.log
  setsid env CUDA_VISIBLE_DEVICES=0 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    /app/run serve-grpc --host 0.0.0.0 --enable-editing-actors --renderer default --cache-size 4 \
    --enable-harmonizer --harmonizer-cache /avl-west/navsafe_dev/.harmonizer-cache \
    --artifact-glob "$SHARD/*.usdz" > /tmp/renderer.log 2>&1 &
  SERVE_PID=$!
  for _ in $(seq 1 240); do
    kill -0 "$SERVE_PID" 2>/dev/null || { say 'renderer exited'; tail -80 /tmp/renderer.log; return 1; }
    grep -q 'Serving on' /tmp/renderer.log && break
    sleep 5
  done
  grep -q 'Serving on' /tmp/renderer.log || { say 'renderer did not bind'; tail -80 /tmp/renderer.log; return 1; }
  for S in "${SCENES[@]}"; do
    grep 'Available scenes' /tmp/renderer.log | grep -Fq "$S" || { say "renderer missing $S"; return 1; }
  done
  say 'renderer ready (fresh cell isolation)'
}
trap stop_renderer EXIT

metrics_scored(){ "$PY" - "$1" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); v=d.get('metrics',{}).get('driving_score')
raise SystemExit(0 if d.get('status')=='scored' and type(v) in (int,float) else 1)
PY
}
mapfile -t MODELS < <(grep -vE '^[[:space:]]*(#|$)' "$MODELS_TSV")
failed=0; completed=0; skipped=0; consecutive=0
for T in "${TOKENS[@]}"; do
  mapfile -t CELLS < <("$PY" - "$CELLS_JSON" "$T" <<'PY'
import json,sys
for r in json.load(open(sys.argv[1])):
 if r['token']==sys.argv[2]: print('\t'.join(str(r.get(k) or '-') for k in ['leaf','token','event','recipe','data_root','asset_harvester_manifest','replay_frames']))
PY
)
  [ ${#CELLS[@]} -gt 0 ] || { say "$T has no assigned hazard cells"; exit 1; }
  B=$(dirname "$(printf '%s' "${CELLS[0]}" | cut -f5)")
  NUREC_GRPC_HANDOFF=$("$PY" -m nexussim.navsafe.eval.bundle --handoff "$B")
  export NUREC_GRPC_HANDOFF
  for MODEL_ROW in "${MODELS[@]}"; do
    IFS=$'\t' read -r SLUG MT CK EXTRA_ENV <<< "$MODEL_ROW"
    case "$CK" in none) CKPT=none;; /*) CKPT="$CK";; *) CKPT="$ROOT/model_zoo/$CK";; esac
    [ "$CKPT" = none ] || [ -e "$CKPT" ] || { say "missing checkpoint $CKPT"; exit 1; }
    unset NAVSAFE_RECOGDRIVE_VLM NAVSAFE_GTRS_BACKBONE NAVSAFE_GTRS_VOCAB NAVSAFE_GTRS_VOCAB_SIZE
    if [ -n "${EXTRA_ENV:-}" ]; then IFS=',' read -ra KVS <<< "$EXTRA_ENV"; for KV in "${KVS[@]}"; do export "$KV"; done; fi
    for CELL in "${CELLS[@]}"; do
      IFS=$'\t' read -r LEAF TOKEN EVENT RECIPE DATA_ROOT AH HANDOFF <<< "$CELL"
      OUT="$OUTROOT/$SLUG/$LEAF/$TOKEN/$EVENT"; LOG="$OUT/eval.log"; TRACE="$OUT/reactivity_trace.zip"
      if grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && metrics_scored "$OUT/navsafe_metrics.json" && "$PY" "$CAMPAIGN_ROOT/audit_trace.py" "$TRACE" >/dev/null; then
        skipped=$((skipped+1)); continue
      fi
      mkdir -p "$OUT"
      if [ -s "$LOG" ]; then mv "$LOG" "$OUT/eval.previous.$(date -u +%Y%m%dT%H%M%SZ).log"; fi
      AH_ARGS=(); [ "$AH" != '-' ] && AH_ARGS=(--asset-harvester-replace "$AH")
      start_renderer || exit 1
      say "run $SLUG $LEAF/$EVENT"
      if CUDA_VISIBLE_DEVICES=1 "$PY" "$REPO/scripts/tools/eval_py123d.py" \
          --scenario-source py123d --py123d-data-root "$DATA_ROOT" --py123d-scene-index 0 \
          --render-backend nurec_grpc --cam-height navsim --model-type "$MT" --checkpoint "$CKPT" \
          --traffic-mode navsafe --recipe "$RECIPE_ROOT/$RECIPE" "${AH_ARGS[@]}" \
          --ego-replay-frames "$HANDOFF" --terminate-on-collision --controller lqr --execution-mode controller \
          --replan-rate 5 --camera-resolution-scale 1.0 --eval-frames 600 --eval-seed 0 \
          --record-reactivity-trace --reactivity-condition hazard --reactivity-group-id "$LEAF/$TOKEN/$EVENT" \
          --output-dir "$OUT" > "$LOG" 2>&1; then rc=0; else rc=$?; fi
      echo "$rc" > "$OUT/exit_code.txt"
      if [ "$rc" -eq 0 ] && grep -qs '^\[eval_py123d\] DONE\.' "$LOG" && metrics_scored "$OUT/navsafe_metrics.json" && "$PY" "$CAMPAIGN_ROOT/audit_trace.py" "$TRACE" > "$OUT/reactivity_trace_audit.json"; then
        completed=$((completed+1)); consecutive=0; say "OK $SLUG $LEAF/$EVENT"
      else
        failed=$((failed+1)); consecutive=$((consecutive+1)); cp /tmp/renderer.log "$OUT/renderer.log" 2>/dev/null || true
        say "FAILED rc=$rc $SLUG $LEAF/$EVENT"; tail -50 "$LOG"
        [ "$consecutive" -lt 3 ] || { say 'three consecutive cells failed; aborting worker for campaign-level diagnosis'; exit 1; }
      fi
    done
  done
done
say "WORKER DONE completed=$completed skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
