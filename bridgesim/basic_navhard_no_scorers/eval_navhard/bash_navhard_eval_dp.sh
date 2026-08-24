#!/bin/bash

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 1 2 10 20 40 80; do
    for EVAL_FRAMES in 80; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      envsubst < ./job_navhard_eval_dp.yaml | kubectl apply -f -
    done
  done
done
