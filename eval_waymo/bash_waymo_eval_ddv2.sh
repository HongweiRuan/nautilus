#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

for SPLIT in 200-1 200-2; do
  for REPLAN_RATE in 5; do
    for EVAL_FRAMES in 80; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      envsubst < ./job_waymo_eval_ddv2.yaml | kubectl apply -f -
    done
  done
done
