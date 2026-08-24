#!/bin/bash

# for SPLIT in 1 2; do
#   for REPLAN_RATE in 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40; do
#     # for EVAL_FRAMES in 40 80; do
#     for EVAL_FRAMES in 120 160 200; do
#       export SPLIT REPLAN_RATE EVAL_FRAMES 
#       envsubst < ./job_navhard_eval_with_calibration.yaml | kubectl delete -f -
#       # envsubst < ./job_navhard_eval_with_calibration_lidar.yaml | kubectl delete -f -
#       # envsubst < ./job_navhard_eval_with_calibration_and_temporal.yaml | kubectl delete -f -
#       # envsubst < ./job_navhard_eval_with_calibration_lidar_and_temporal.yaml | kubectl delete -f -
#       envsubst < ./job_navhard_eval_baseline.yaml | kubectl delete -f -
#     done
#   done
# done


# ALPHA=0.5
# ALPHA_SAFE=0-5
# NUM_SAMPLES=5
# export ALPHA ALPHA_SAFE NUM_SAMPLES

# for SPLIT in 1 2; do
#   for REPLAN_RATE in 1 2 3 4 5 6 7 8 9 10 15 20 25 30 35 40; do
#     for EVAL_FRAMES in 40 80; do
#       export SPLIT REPLAN_RATE EVAL_FRAMES
#       envsubst < ./job_navhard_eval_adv_with_calibration.yaml | kubectl delete -f -
#       envsubst < ./job_navhard_eval_adv_with_calibration_and_temporal.yaml | kubectl delete -f -
#       envsubst < ./job_navhard_eval_adv_baseline.yaml | kubectl delete -f -
#     done
#   done
# done


ALPHA=0.5
ALPHA_SAFE=0-5
NUM_SAMPLES=5
export ALPHA ALPHA_SAFE NUM_SAMPLES

for SPLIT in 210-1 211-1; do
  for REPLAN_RATE in 1 2 5 10 15 20 25 30 35 40; do
    for EVAL_FRAMES in 40 80; do
      export SPLIT REPLAN_RATE EVAL_FRAMES
      # envsubst < ./job_navhard_eval_with_calibration.yaml | kubectl apply -f -
      # envsubst < ./job_navhard_eval_with_calibration_and_temporal.yaml | kubectl apply -f -
      envsubst < ./job_navhard_eval_baseline.yaml | kubectl apply -f -
    done
  done
done


# ACTION="${1:-apply}"  # default to apply, can pass "delete" as argument

# for SPLIT in 1 2; do
#   for REPLAN_RATE in 2 8; do
#     for EVAL_FRAMES in 40 80; do
#       for ALPHA in 0.1 0.5 0.9; do
#         for NUM_SAMPLES in 5 20 40; do
#           ALPHA_SAFE=$(echo "$ALPHA" | tr '.' '-')
#           export SPLIT REPLAN_RATE EVAL_FRAMES ALPHA ALPHA_SAFE NUM_SAMPLES
          
#           echo "Processing: SPLIT=${SPLIT} REPLAN_RATE=${REPLAN_RATE} EVAL_FRAMES=${EVAL_FRAMES} ALPHA=${ALPHA} NUM_SAMPLES=${NUM_SAMPLES}"
#           envsubst < ./job_navhard_eval_with_calibration_and_temporal.yaml | kubectl "${ACTION}" -f -
#         done
#       done
#     done
#   done
# done
