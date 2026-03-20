#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
NUM_GROUPS=1
export ALPHA ALPHA_SAFE NUM_SAMPLES NUM_GROUPS

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 1 5; do
    for EVAL_FRAMES in 40 80 120 160; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      envsubst '${SPLIT} ${REPLAN_RATE} ${EVAL_FRAMES} ${NUM_GROUPS}' < ./job_navhard_eval_ddv2_epdms_ego_adaptive_col_60.yaml | kubectl apply -f -
    done
  done
done
