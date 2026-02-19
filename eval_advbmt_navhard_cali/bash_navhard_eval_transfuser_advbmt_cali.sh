#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 1 2 5 10 15 20 25 30 35 40; do
    for EVAL_FRAMES in 40 80; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      envsubst < ./job_navhard_eval_transfuser_advbmt_cali.yaml | kubectl apply -f -
    done
  done
done
