#!/bin/bash

set -e

echo "=== eval_waymo: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_waymo
bash bash_waymo_eval_dd.sh

echo "=== eval_waymo: ddv2 ==="
bash bash_waymo_eval_ddv2.sh

echo "=== eval_waymo: rap ==="
bash bash_waymo_eval_rap.sh

echo "=== eval_waymo_ego_cali_ttc: dd ==="
cd /Users/hongwei/Desktop/avl/nautilus/eval_waymo_ego_cali_ttc
bash bash_waymo_eval_dd_ego_ttc.sh

echo "=== eval_waymo_ego_cali_ttc: ddv2 ==="
bash bash_waymo_eval_ddv2_ego_ttc.sh

echo "=== eval_waymo_ego_cali_ttc: rap ==="
bash bash_waymo_eval_rap_ego_ttc.sh

# echo "=== eval_waymo_epdms_fast_cali: dd ==="
# cd /Users/hongwei/Desktop/avl/nautilus/eval_waymo_epdms_fast_cali
# bash bash_waymo_eval_dd_EPDMS_fast_cali.sh

# echo "=== eval_waymo_epdms_fast_cali: ddv2 ==="
# bash bash_waymo_eval_ddv2_EPDMS_fast_cali.sh

# echo "=== eval_waymo_epdms_fast_cali: rap ==="
# bash bash_waymo_eval_rap_EPDMS_fast_cali.sh

# echo "=== All waymo eval jobs submitted ==="
