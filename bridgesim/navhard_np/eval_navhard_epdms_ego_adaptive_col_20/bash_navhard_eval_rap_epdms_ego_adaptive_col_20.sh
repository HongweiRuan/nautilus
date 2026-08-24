#!/bin/bash

REPLAN_RATE=5
EVAL_FRAMES=80
export REPLAN_RATE EVAL_FRAMES

for SPLIT in 210-1 211-1; do
  for NUM_PROPOSALS in 1 2 5 10 20 30 40 50 64; do
    export SPLIT NUM_PROPOSALS
    envsubst '${SPLIT} ${REPLAN_RATE} ${EVAL_FRAMES} ${NUM_PROPOSALS}' < ./job_navhard_eval_rap_epdms_ego_adaptive_col_20.yaml | kubectl apply -f -
  done
done
