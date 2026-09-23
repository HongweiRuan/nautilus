#!/bin/bash
# Robin's bosch-summer deploy recipe (docs/deploy/dinov2_only_setting.md), sections 4/5 (SETTING=dinov2) and 8.2 (SETTING=best),
# BEFORE or AFTER (MODE=before|after). Runs a 64-scene smoke first, then the full navtest split (12,146 scenes).
#   SETTING=dinov2|best MODE=before|after PROCS=8 bash run_eval.sh
set -euo pipefail
SETTING=${SETTING:?dinov2|best}; MODE=${MODE:?before|after}; PROCS=${PROCS:-8}; SKIP_SMOKE=${SKIP_SMOKE:-0}
REPO=/hugsim-storage/bosch-summer
RUN_DIR=$REPO/exp/hongwei_runs

echo "=== [$(date -u +%T)] env: conda python 3.10 + torch 2.5.1 cu124 (scripts/drivor_action/local/install_drivor_local.sh) ==="
apt-get update -qq && apt-get install -y -qq libgl1 libglib2.0-0 > /dev/null
source /opt/conda/etc/profile.d/conda.sh
conda create -y -q -p /opt/drivor python=3.10 pip > /dev/null
conda activate /opt/drivor
# keep the repo layout: ext_scorer/vocab_picker.py imports <repo>/scripts/drivor_action/train_vocab_picker.py
rm -rf /root/bosch-summer && mkdir -p /root/bosch-summer && cp -r $REPO/DrivoR $REPO/scripts /root/bosch-summer/
cd /root/bosch-summer/DrivoR
pip install -q torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu124
pip install -q "numpy<2"
pip install -q -r requirements.txt
pip install -q -U "pytorch-lightning>=2.5,<2.6"
pip install -q -e nuplan-devkit --no-deps
pip install -q wandb huggingface_hub safetensors
mkdir -p weights/vit_small_patch14_reg4_dinov2.lvd142m
cp $RUN_DIR/dinov2/model.safetensors weights/vit_small_patch14_reg4_dinov2.lvd142m/model.safetensors

export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1
export NAVSIM_DEVKIT_ROOT=/root/bosch-summer/DrivoR
export OPENSCENE_DATA_ROOT=/avl-west/navsim
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NUPLAN_MAPS_ROOT=/avl-west/nuplan/maps
export NAVSIM_EXP_ROOT=$RUN_DIR/exp
export SUBSCORE_PATH=$NAVSIM_EXP_ROOT
export PYTHONPATH=$NAVSIM_DEVKIT_ROOT
export HYDRA_FULL_ERROR=1
mkdir -p $NAVSIM_EXP_ROOT
python -c "import torch, navsim; from navsim.agents.drivor_action import DrivorActionAgent; print('torch', torch.__version__, torch.cuda.get_device_name(0)); print('navsim', navsim.__file__)"
python -c "import sys; sys.path.insert(0, '/root/bosch-summer/scripts/drivor_action'); import train_vocab_picker; print('train_vocab_picker OK')"
# the metric cache was pickled under numpy 2; alias numpy._core -> numpy.core for this numpy<2 env (np2_pickle_compat.py)
cp $RUN_DIR/np2_pickle_compat.py "$(python -c 'import site; print(site.getsitepackages()[0])')/sitecustomize.py"
python - <<'PY2'
import glob, lzma, pickle, numpy
p = next(glob.iglob("/closed-loop-e2e/drivor-exp/metric_cache/2021.05.25.14.16.10_veh-35_00083_00485/*/*/metric_cache.pkl"))
with lzma.open(p, "rb") as f:
    mc = pickle.load(f)
print("metric cache load OK:", type(mc).__name__, "| numpy", numpy.__version__)
PY2

if [ "$SETTING" = "dinov2" ]; then
  D=$REPO/deploy_files
  P=$D/picker
  M=$(for n in picker_full_kd1_s0 picker_full_kd1_s1 picker_full_kd1_s2 picker_reg_cpo_s0 picker_reg_cpo_s1 picker_reg_cpo_s2; do echo -n "$P/$n/picker_best.pt,"; done | sed 's/,$//')
  SCENE_ARGS="agent.config.ext_scorer.vocab_picker.scene_source=policy"
  AFTER_CKPT=$D/policy/v_linear_demo_ft_reg_pdms_lr3_s1.ckpt
else
  D=$REPO/deploy_files_best
  P=$D/picker
  M=$(for s in 0 1 2 3 4 5; do echo -n "$P/picker_geoup_kd1_cpoworst03_s$s/picker_best.pt,"; done | sed 's/,$//')
  SCENE_ARGS="agent.config.ext_scorer.vocab_picker.scene_source=geoup agent.config.ext_scorer.vocab_picker.geoup_checkpoint=$D/geoup/epoch_4.ckpt agent.config.ext_scorer.vocab_picker.geoup_prediction_type=v agent.config.ext_scorer.vocab_picker.geoup_schedule=gvp"
  AFTER_CKPT=$D/policy/v_linear_demo_ft_imp_lr3_s2.ckpt
fi
if [ "$MODE" = "before" ]; then
  CKPT=$D/policy/last.ema_bf16.ckpt; REFINE_ARGS=""
else
  CKPT=$AFTER_CKPT
  REFINE_ARGS="agent.config.refine.enabled=true agent.config.refine.refine_pick=true agent.config.refine.rank=8 agent.config.refine.alpha=8.0 agent.config.refine.active_steps=4 agent.config.refine.skip_last=true agent.config.freeze_encoder=true"
fi
# every ray worker loads the checkpoints itself: read them from local disk, not CephFS (GeoUP alone is 6.3 GB x PROCS)
echo "=== [$(date -u +%T)] copying $D to local disk ==="
rm -rf /root/deploy && cp -r $D /root/deploy
M=${M//$D//root/deploy}; SCENE_ARGS=${SCENE_ARGS//$D//root/deploy}; CKPT=${CKPT//$D//root/deploy}; D=/root/deploy
du -sh $D
EXP=${SETTING}_${MODE}

run() {  # $1 = experiment name, $2 = extra overrides
  echo "=== [$(date -u +%T)] $1 | ckpt $CKPT | $PROCS ray procs ==="
  python $NAVSIM_DEVKIT_ROOT/navsim/planning/script/run_pdm_score.py \
    train_test_split=navtest train_test_split/scene_filter=navtest $2 \
    navsim_log_path=/avl-west/navsim/test_navsim_logs/test sensor_blobs_path=/avl-west/navsim/test_sensor_blobs/test \
    metric_cache_path=/closed-loop-e2e/drivor-exp/metric_cache \
    experiment_name=$1 worker=ray_distributed worker.threads_per_node=$PROCS \
    agent=drivor_action "agent.checkpoint_path='$CKPT'" \
    agent.config.ap.layers=4 agent.config.ap.heads=8 agent.config.ap.d_model=256 agent.config.ap.ffn_hidden=1024 \
    agent.config.flow.prediction_type=v agent.config.flow.schedule=linear agent.config.flow.t_eps=0.05 \
    agent.config.flow.num_denoise_steps=10 agent.config.ema.use_at_eval=true \
    $REFINE_ARGS \
    agent.config.ext_scorer.kind=vocab_picker agent.config.ext_scorer.checkpoint_path=${M%%,*} agent.config.ext_scorer.select=proposals \
    "agent.config.ext_scorer.vocab_picker.models=[$M]" $SCENE_ARGS \
    agent.config.ext_scorer.vocab_picker.weights=v1 agent.config.ext_scorer.vocab_picker.ensemble=logit \
    agent.config.flow.prune_steps=0 agent.config.flow.prune_keep=16 \
    agent.config.flow.num_val_samples=64 agent.config.flow.init_noise=vocab agent.config.flow.init_noise_scale=1.0 \
    agent.config.flow.init_noise_pool_mult=4 "agent.config.flow.init_noise_vocab_file=$D/vocab/noise_vocab_64.npy" \
    +pdm_best_of_k=false +pdm_noise_seed=0
  CSV=$(ls -t "$NAVSIM_EXP_ROOT/ke/$1"/*/*.csv | head -1)
  echo "csv: $CSV"
  python - "$CSV" <<'PY'
import sys, pandas as pd
df = pd.read_csv(sys.argv[1]); df = df[df.token != "average"]
print(f"RESULT {sys.argv[1]}: {len(df)} tokens, valid {df.valid.mean():.4f}, PDMS {df.score.mean():.5f}")
PY
}

[ "$SKIP_SMOKE" = "1" ] || run ${EXP}_smoke "train_test_split.scene_filter.max_scenes=64"
run $EXP ""
echo "=== [$(date -u +%T)] done $EXP ==="
