#!/bin/bash

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_dir() {
  local dir="$1"
  echo "=== Launching scripts in $dir ==="
  for script in "$SCRIPT_DIR/$dir"/*.sh; do
    echo "  -> Running $script"
    (cd "$SCRIPT_DIR/$dir" && bash "$(basename "$script")")
  done
}

run_dir eval_navhard_idm_baseline
run_dir eval_navhard_idm_ego
run_dir eval_navhard_idm_fast
run_dir eval_navhard_idm_v1
run_dir eval_nuscenes_baseline
run_dir eval_nuscenes_ego
run_dir eval_nuscenes_fast
run_dir eval_nuscenes_v1
run_dir eval_waymo
run_dir eval_waymo_ego_cali
run_dir eval_waymo_ego_cali_v1
run_dir eval_waymo_epdms_fast_cali

echo "=== All eval jobs submitted ==="
