#!/bin/bash
set -e

for NUM_GROUPS in 2 4 10; do
  export NUM_GROUPS

  # navhard log_replay
  cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_epdms_ego_adaptive_col_60
  bash bash_navhard_eval_dd_epdms_ego_adaptive_col_60.sh

  # advbmt log_replay
  cd /Users/hongwei/Desktop/avl/nautilus/eval_advbmt_navhard_epdms_ego_adaptive_col_60
  bash bash_advbmt_navhard_eval_dd_epdms_ego_adaptive_col_60.sh

  # navhard IDM
  cd /Users/hongwei/Desktop/avl/nautilus/eval_navhard_idm_epdms_ego_adaptive_col_60
  bash bash_navhard_idm_eval_dd_epdms_ego_adaptive_col_60.sh

done

echo "All dd eval jobs submitted."
