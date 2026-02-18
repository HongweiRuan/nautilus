#!/bin/bash

# Expert evaluation parameters
ALPHA=0.5
ALPHA_SAFE=0-5 
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

# Expert evaluation parameter combinations - fixed pairs
for SPLIT in 210-1 211-1; do
  # Pair 1: EVAL_FRAMES=40 with EGO_REPLAY_FRAMES=60
  EGO_REPLAY_FRAMES=60
  EVAL_FRAMES=40
  export SPLIT EGO_REPLAY_FRAMES EVAL_FRAMES
  envsubst < ./job_navhard_eval_expert.yaml | kubectl apply -f -
  
  # Pair 2: EVAL_FRAMES=80 with EGO_REPLAY_FRAMES=100
  EGO_REPLAY_FRAMES=100
  EVAL_FRAMES=80
  export SPLIT EGO_REPLAY_FRAMES EVAL_FRAMES
  envsubst < ./job_navhard_eval_expert.yaml | kubectl apply -f -
done