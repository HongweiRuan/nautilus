#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 40; do
    for EVAL_FRAMES in 120 160 200; do
      for NUM_GROUPS in 1; do
        export SPLIT REPLAN_RATE EVAL_FRAMES NUM_GROUPS
        envsubst '${SPLIT} ${REPLAN_RATE} ${EVAL_FRAMES} ${NUM_GROUPS}' < ./job_navhard_eval_ddv2_coarse_topk_cali.yaml | kubectl apply -f -
      done
    done
  done
done
