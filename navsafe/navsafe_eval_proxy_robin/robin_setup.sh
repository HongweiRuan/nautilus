# Sourced by the patched campaign run_worker.sh right after the NexusSim venv is ready ($REPO, $PY, $ROOT, say() set).
# Installs Robin's drivor_action adapter into the frozen runtime and stages his bosch-summer agent on local disk.
RB=/avl-west/navsafe_eval/robin_proxy_eval
BOSCH=/hugsim-storage/bosch-summer
DA_ROOT=/root/bosch-summer
cp "$RB/drivor_action.py" "$REPO/nexussim/policy/sensor/drivor_action.py" || { say 'adapter copy failed'; exit 1; }
"$PY" - <<'PY'
from pathlib import Path
p = Path('/root/ns/nexussim/engine/registry.py'); s = p.read_text(); needle = '    "nexussim.policy.sensor.drivor_action",'
if needle not in s:
    anchor = '    "nexussim.policy.sensor.ltf",'
    if anchor not in s: raise SystemExit('registry anchor missing')
    p.write_text(s.replace(anchor, anchor + '\n' + needle))
PY
[ $? -eq 0 ] || { say 'drivor_action registration failed'; exit 1; }
say "staging bosch-summer DrivoR fork + best-PDMS deploy package to $DA_ROOT"
rm -rf "$DA_ROOT" && mkdir -p "$DA_ROOT" && cp -r "$BOSCH/DrivoR" "$BOSCH/scripts" "$BOSCH/deploy_files_best" "$DA_ROOT/" || { say 'bosch-summer staging failed'; exit 1; }
mkdir -p "$DA_ROOT/DrivoR/weights/vit_small_patch14_reg4_dinov2.lvd142m"
cp "$BOSCH/exp/hongwei_runs/dinov2/model.safetensors" "$DA_ROOT/DrivoR/weights/vit_small_patch14_reg4_dinov2.lvd142m/" || { say 'DINOv2 weights missing'; exit 1; }
uv pip install --python "$PY" --no-deps "pytorch-lightning>=2.5,<2.6" lightning-utilities torchmetrics >/dev/null || { say 'pytorch-lightning install failed'; exit 1; }
export NAVSAFE_DA_ROOT=$DA_ROOT
PYTHONPATH="$DA_ROOT/DrivoR:$ROOT/aug_zoo/SimScale/nuplan-devkit:$REPO" "$PY" -c "import navsim; assert navsim.__file__.startswith('$DA_ROOT/DrivoR'), navsim.__file__; from navsim.agents.drivor_action.drivor_action_agent import DrivorActionAgent; import sys; sys.path.insert(0, '$DA_ROOT/scripts/drivor_action'); import train_vocab_picker; from nexussim.policy.sensor.drivor_action import DrivorActionAdapter" || { say 'drivor_action import failed'; exit 1; }
say "drivor_action ready; controller=$CONTROLLER"
