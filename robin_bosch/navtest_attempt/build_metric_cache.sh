#!/bin/bash
# navtest metric cache built with Robin's DrivoR fork in his numpy<2 env (docs/deploy/dinov2_only_setting.md section 3;
# DrivoR/metric_caching.sh), replacing the numpy-2 cache built from DrivoR_vanilla.
#   THREADS=48 bash build_metric_cache.sh
set -euo pipefail
THREADS=${THREADS:-48}
REPO=/hugsim-storage/bosch-summer
CACHE_PATH=${CACHE_PATH:-/closed-loop-e2e/drivor-exp/metric_cache_bosch}

echo "=== [$(date -u +%T)] env: conda python 3.10 + torch 2.5.1 cu124 (scripts/drivor_action/local/install_drivor_local.sh) ==="
apt-get update -qq && apt-get install -y -qq libgl1 libglib2.0-0 > /dev/null
source /opt/conda/etc/profile.d/conda.sh
conda create -y -q -p /opt/drivor python=3.10 pip > /dev/null
conda activate /opt/drivor
rm -rf /root/bosch-summer && mkdir -p /root/bosch-summer && cp -r $REPO/DrivoR /root/bosch-summer/DrivoR && ln -s $REPO/scripts /root/bosch-summer/scripts
cd /root/bosch-summer/DrivoR
pip install -q torch==2.5.1 torchvision==0.20.1 --index-url https://download.pytorch.org/whl/cu124
pip install -q "numpy<2"
pip install -q -r requirements.txt
pip install -q -U "pytorch-lightning>=2.5,<2.6"
pip install -q -e nuplan-devkit --no-deps

export OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1
export NAVSIM_DEVKIT_ROOT=/root/bosch-summer/DrivoR
export OPENSCENE_DATA_ROOT=/avl-west/navsim
export NUPLAN_MAP_VERSION=nuplan-maps-v1.0
export NUPLAN_MAPS_ROOT=/avl-west/nuplan/maps
export NAVSIM_EXP_ROOT=$REPO/exp/hongwei_runs/exp
export PYTHONPATH=$NAVSIM_DEVKIT_ROOT
export HYDRA_FULL_ERROR=1
python -c "import numpy, navsim; print('numpy', numpy.__version__, '| navsim', navsim.__file__)"

if [ -n "$(find "$CACHE_PATH" -name metric_cache.pkl -print -quit 2>/dev/null)" ]; then
  echo "ERROR: $CACHE_PATH already has metric_cache.pkl files; refusing to mix caches"; exit 1
fi
echo "=== [$(date -u +%T)] metric caching navtest -> $CACHE_PATH | $THREADS ray workers ==="
python $NAVSIM_DEVKIT_ROOT/navsim/planning/script/run_metric_caching.py \
  train_test_split=navtest \
  navsim_log_path=/avl-west/navsim/test_navsim_logs/test \
  cache.cache_path=$CACHE_PATH \
  worker=ray_distributed_no_torch worker.threads_per_node=$THREADS

N=$(find "$CACHE_PATH" -name metric_cache.pkl | wc -l)
echo "RESULT metric_cache.pkl files: $N (navtest = 12146)"
python - "$CACHE_PATH" <<'PY'
import glob, lzma, pickle, sys
p = next(iter(glob.iglob(sys.argv[1] + "/2*/*/*/metric_cache.pkl")))
with lzma.open(p, "rb") as f:
    mc = pickle.load(f)
print("load OK:", type(mc).__name__, p)
PY
echo "=== [$(date -u +%T)] done ==="
