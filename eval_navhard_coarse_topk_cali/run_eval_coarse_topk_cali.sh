#!/bin/bash
set -e

# Arguments
MODEL_TYPE="$1"
CHECKPOINT="$2"
CONFIG_OR_ANCHOR="$3"
SCENARIO_BASE_PATH="$4"
OUTPUT_DIR="$5"
REPLAN_RATE="$6"
EVAL_FRAMES="$7"
SCENE_LIST_FILE="$8"
BEV_CALIBRATOR_CHECKPOINT="$9"
V2_SCORER_CHECKPOINT="${10}"

# Read file line by line
while read -r scene_id || [ -n "$scene_id" ]; do
    # Skip empty lines
    [ -z "$scene_id" ] && continue

    echo "Processing: $scene_id"
    EXTRA_ARGS=""
    if [ -n "$CONFIG_OR_ANCHOR" ]; then
        case "$CONFIG_OR_ANCHOR" in
            *.py)  EXTRA_ARGS="--config $CONFIG_OR_ANCHOR" ;;
            *)     EXTRA_ARGS="--plan-anchor-path $CONFIG_OR_ANCHOR" ;;
        esac
    fi
    /opt/conda/envs/mdsn/bin/python /root/MetaBench/bridgesim/evaluation/unified_evaluator.py \
        --model-type "$MODEL_TYPE" \
        --checkpoint "$CHECKPOINT" \
        $EXTRA_ARGS \
        --trajectory-scorer coarse_topk \
        --num-groups 20 \
        --v2-scorer-checkpoint "$V2_SCORER_CHECKPOINT" \
        --scenario-path "${SCENARIO_BASE_PATH}/${scene_id}" \
        --traffic-mode log_replay \
        --output-dir "$OUTPUT_DIR" \
        --eval-mode closed_loop \
        --controller pure_pursuit \
        --replan-rate "$REPLAN_RATE" \
        --ego-replay-frames 20 \
        --eval-frames "$EVAL_FRAMES" \
        --enable-bev-calibrator \
        --bev-calibrator-checkpoint "$BEV_CALIBRATOR_CHECKPOINT" \
        --bev-sample-steps 10

done < <(tr -d '\r' < "$SCENE_LIST_FILE")

echo "All scenes processed."
