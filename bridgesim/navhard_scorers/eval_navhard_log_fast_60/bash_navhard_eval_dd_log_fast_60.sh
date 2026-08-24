#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 5; do
    for EVAL_FRAMES in 80; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      envsubst < ./job_navhard_eval_dd_log_fast_60.yaml | kubectl apply -f -
    done
  done
done
