#!/bin/bash

set -e

echo "=== eval_advbmt_navhard_ego_60: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_advbmt_navhard_ego_60
bash bash_advbmt_navhard_eval_dd_ego.sh

echo "=== eval_advbmt_navhard_ego_60: ddv2 ==="
bash bash_advbmt_navhard_eval_ddv2_ego.sh

echo "=== eval_advbmt_navhard_ego_60: rap ==="
bash bash_advbmt_navhard_eval_rap_ego.sh

echo "=== eval_advbmt_navhard_fast_60: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_advbmt_navhard_fast_60
bash bash_advbmt_navhard_eval_dd_fast.sh

echo "=== eval_advbmt_navhard_fast_60: ddv2 ==="
bash bash_advbmt_navhard_eval_ddv2_fast.sh

echo "=== eval_advbmt_navhard_fast_60: rap ==="
bash bash_advbmt_navhard_eval_rap_fast.sh

echo "=== eval_navhard_idm_v1: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_idm_v1
bash bash_navhard_eval_dd_idm_v1.sh

echo "=== eval_navhard_idm_v1: ddv2 ==="
bash bash_navhard_eval_ddv2_idm_v1.sh

echo "=== eval_navhard_idm_v1: rap ==="
bash bash_navhard_eval_rap_idm_v1.sh

echo "=== eval_navhard_idm_baseline: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_idm_baseline
bash bash_navhard_eval_dd_idm_baseline.sh

echo "=== eval_navhard_idm_baseline: ddv2 ==="
bash bash_navhard_eval_ddv2_idm_baseline.sh

echo "=== eval_navhard_idm_baseline: rap ==="
bash bash_navhard_eval_rap_idm_baseline.sh

echo "=== eval_navhard_idm_fast: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_idm_fast
bash bash_navhard_eval_dd_idm_fast.sh

echo "=== eval_navhard_idm_fast: ddv2 ==="
bash bash_navhard_eval_ddv2_idm_fast.sh

echo "=== eval_navhard_idm_fast: rap ==="
bash bash_navhard_eval_rap_idm_fast.sh

echo "=== eval_navhard_idm_ego: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_idm_ego
bash bash_navhard_eval_dd_idm_ego.sh

echo "=== eval_navhard_idm_ego: ddv2 ==="
bash bash_navhard_eval_ddv2_idm_ego.sh

echo "=== eval_navhard_idm_ego: rap ==="
bash bash_navhard_eval_rap_idm_ego.sh

echo "=== eval_navhard_log_ego_60: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_log_ego_60
bash bash_navhard_eval_dd_log_ego_60.sh

echo "=== eval_navhard_log_ego_60: ddv2 ==="
bash bash_navhard_eval_ddv2_log_ego_60.sh

echo "=== eval_navhard_log_ego_60: rap ==="
bash bash_navhard_eval_rap_log_ego_60.sh

echo "=== eval_navhard_log_fast_60: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_log_fast_60
bash bash_navhard_eval_dd_log_fast_60.sh

echo "=== eval_navhard_log_fast_60: ddv2 ==="
bash bash_navhard_eval_ddv2_log_fast_60.sh

echo "=== eval_navhard_log_fast_60: rap ==="
bash bash_navhard_eval_rap_log_fast_60.sh

echo "=== All eval jobs submitted ==="
