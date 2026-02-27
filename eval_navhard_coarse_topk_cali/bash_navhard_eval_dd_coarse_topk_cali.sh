#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 1 5 10 20 40; do
    for EVAL_FRAMES in 40 80; do
      for NUM_GROUPS in 1 2 5 10 20 50 100 500 1000; do
        export SPLIT REPLAN_RATE EVAL_FRAMES NUM_GROUPS
        envsubst '${SPLIT} ${REPLAN_RATE} ${EVAL_FRAMES} ${NUM_GROUPS}' < ./job_navhard_eval_dd_coarse_topk_cali.yaml | kubectl apply -f -
      done
    done
  done
done
