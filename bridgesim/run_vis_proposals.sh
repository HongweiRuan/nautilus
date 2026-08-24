#!/bin/bash
# Run trajectory proposal visualization for DDv1 & DDv2 across 5 scenarios.
#
# Usage:
#   bash scripts/run_vis_proposals.sh
#   bash scripts/run_vis_proposals.sh --model diffusiondrivev2   # single model
#   bash scripts/run_vis_proposals.sh --scenario sd_49074bfb7c9e5c26  # single scenario

set -e

# --- Paths ---
SCENARIO_BASE="/avl-west/navsim/navhard_md_logs"
DD_CKPT="/root/diffusiondrive_navsim_88p1_PDMS"
DDV2_CKPT="/root/diffusiondrivev2_sel.ckpt"
PLAN_ANCHOR="/root/kmeans_navsim_traj_20.npy"
OUTPUT_DIR="/root/MetaBench/vis_proposals_output"
EVAL_FRAMES=40

# --- Scenarios ---
SCENARIOS=(
    # "sd_49074bfb7c9e5c26"
    # "sd_8846d60884435288"
    "sd_ae472d675a965aca"
    # "sd_197f2dea642850e7"
    # "sd_e024bd23594b5a13"
)

# --- Parse args ---
FILTER_MODEL=""
FILTER_SCENARIO=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --model) FILTER_MODEL="$2"; shift 2 ;;
        --scenario) FILTER_SCENARIO="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# --- Models to run ---
MODELS=("diffusiondrive" "diffusiondrivev2")
if [[ -n "$FILTER_MODEL" ]]; then
    MODELS=("$FILTER_MODEL")
fi

# --- Run ---
for MODEL in "${MODELS[@]}"; do
    if [[ "$MODEL" == "diffusiondrive" ]]; then
        CKPT="$DD_CKPT"
        V2_FLAG="--v2-checkpoint $DDV2_CKPT"
    else
        CKPT="$DDV2_CKPT"
        V2_FLAG=""
    fi

    for SCENARIO in "${SCENARIOS[@]}"; do
        if [[ -n "$FILTER_SCENARIO" && "$SCENARIO" != "$FILTER_SCENARIO" ]]; then
            continue
        fi

        SCENARIO_PATH="${SCENARIO_BASE}/${SCENARIO}"
        echo "============================================"
        echo "Model: $MODEL | Scenario: $SCENARIO"
        echo "============================================"

        python scripts/vis_proposals_scored.py \
            --model-type "$MODEL" \
            --checkpoint "$CKPT" \
            --plan-anchor-path "$PLAN_ANCHOR" \
            $V2_FLAG \
            --scenario-path "$SCENARIO_PATH" \
            --output-dir "$OUTPUT_DIR" \
            --eval-frames "$EVAL_FRAMES"

        echo ""
    done
done

echo "All done! Results in: $OUTPUT_DIR"
