#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
NUM_GROUPS=1
export ALPHA ALPHA_SAFE NUM_SAMPLES NUM_GROUPS

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 1; do
    for EVAL_FRAMES in 80; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      envsubst '${SPLIT} ${REPLAN_RATE} ${EVAL_FRAMES} ${NUM_GROUPS}' < ./job_advbmt_navhard_eval_ddv2_epdms_ego_ttc_softcol_60.yaml | kubectl apply -f -
    done
  done
done
