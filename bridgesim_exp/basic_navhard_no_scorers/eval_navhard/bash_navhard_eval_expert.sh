#!/bin/bash

# Expert evaluation parameters
ALPHA=0.5
ALPHA_SAFE=0-5 
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

# Expert evaluation parameter combinations - fixed pairs
for SPLIT in 210-1 211-1; do
  EGO_REPLAY_FRAMES=100
  EVAL_FRAMES=80
  export SPLIT EGO_REPLAY_FRAMES EVAL_FRAMES
  envsubst < ./job_navhard_eval_expert.yaml | kubectl apply -f -

  # Pair 1: EVAL_FRAMES=120 with EGO_REPLAY_FRAMES=140
  # EGO_REPLAY_FRAMES=140
  # EVAL_FRAMES=120
  # export SPLIT EGO_REPLAY_FRAMES EVAL_FRAMES
  # envsubst < ./job_navhard_eval_expert.yaml | kubectl apply -f -

  # # Pair 3: EVAL_FRAMES=160 with EGO_REPLAY_FRAMES=180
  # EGO_REPLAY_FRAMES=180
  # EVAL_FRAMES=160
  # export SPLIT EGO_REPLAY_FRAMES EVAL_FRAMES
  # envsubst < ./job_navhard_eval_expert.yaml | kubectl apply -f -
  
  # # Pair 3: EVAL_FRAMES=200 with EGO_REPLAY_FRAMES=220
  # EGO_REPLAY_FRAMES=220
  # EVAL_FRAMES=200
  # export SPLIT EGO_REPLAY_FRAMES EVAL_FRAMES
  # envsubst < ./job_navhard_eval_expert.yaml | kubectl apply -f -
done