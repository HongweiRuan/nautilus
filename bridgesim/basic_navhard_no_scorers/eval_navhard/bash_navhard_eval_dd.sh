#!/bin/bash

ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 1 2 5 10 20 40; do
    for EVAL_FRAMES in 80; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      envsubst < ./job_navhard_eval_dd.yaml | kubectl apply -f -
    done
  done
  # for REPLAN_RATE in 40; do
  #   for EVAL_FRAMES in 40; do
  #     export SPLIT REPLAN_RATE EVAL_FRAMES
  #     envsubst < ./job_navhard_eval_dd.yaml | kubectl apply -f -
  #   done
  # done
done
