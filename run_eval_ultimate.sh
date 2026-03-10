#!/bin/bash
set -e

# ==============================================================================
# run_eval_ultimate.sh — Universal closed-loop evaluation script
#
# Consolidates all run_eval_*.sh / run_rap_*.sh / run_waymo_*.sh scripts into
# one flexible entry point.  Every knob exposed by the individual scripts is
# available as a named flag here; anything not recognised is forwarded verbatim
# to the Python evaluator.
#
# Usage:
#   run_eval_ultimate.sh [OPTIONS] [-- EXTRA_PYTHON_ARGS...]
#
# Required options:
#   --model-type          MODEL_TYPE
#   --checkpoint          PATH
#   --scenario-base-path  PATH
#   --output-dir          PATH
#   --replan-rate         N
#   --eval-frames         N
#   --scene-list          FILE   (one scene-id per line)
#
# Optional options (defaults in parentheses):
#   --config-or-anchor    PATH   .py → --config, otherwise → --plan-anchor-path
#   --traffic-mode        MODE   (log_replay)   e.g. log_replay | IDM
#   --ego-replay-frames   N      (20)
#   --eval-mode           MODE   (closed_loop)
#   --controller          NAME   (pure_pursuit)
#   --trajectory-scorer   NAME   confidence | epdms_ego | epdms_fast |
#                                epdms_ego_v1 | coarse_topk  (omit = no scorer)
#   --num-groups          N      passed when scorer is set
#   --bev-calibrator-checkpoint PATH  enables --enable-bev-calibrator flag
#   --bev-sample-steps    N      (10)  only used with bev-calibrator-checkpoint
#   --v2-scorer-checkpoint PATH  for coarse_topk scorer
#   --image-source        NAME   e.g. rasterized_3d  (omit = default)
#   --score-start-frame   N      (omit = not passed)
#
# Extra Python args:
#   Append `-- --some-flag value` at the end to pass arbitrary flags directly
#   to unified_evaluator.py.  Alternatively, any flag not recognised above is
#   also collected and forwarded.
#
# Examples:
#   # Basic log-replay eval (mirrors run_eval.sh)
#   run_eval_ultimate.sh \
#     --model-type my_model --checkpoint /ckpt/model.pt \
#     --scenario-base-path /data/scenarios --output-dir /out \
#     --replan-rate 5 --eval-frames 200 --scene-list scenes.txt
#
#   # IDM traffic + epdms_fast scorer + BEV calibrator (mirrors run_eval_idm_fast.sh)
#   run_eval_ultimate.sh \
#     --model-type my_model --checkpoint /ckpt/model.pt \
#     --scenario-base-path /data/scenarios --output-dir /out \
#     --replan-rate 5 --eval-frames 200 --scene-list scenes.txt \
#     --traffic-mode IDM \
#     --trajectory-scorer epdms_fast \
#     --bev-calibrator-checkpoint /ckpt/bev_cal.pt
#
#   # rasterized_3d image source + epdms_ego_v1 scorer, 60 ego-replay frames
#   run_eval_ultimate.sh \
#     --model-type my_model --checkpoint /ckpt/model.pt \
#     --scenario-base-path /data/scenarios --output-dir /out \
#     --replan-rate 5 --eval-frames 200 --scene-list scenes.txt \
#     --image-source rasterized_3d \
#     --trajectory-scorer epdms_ego_v1 \
#     --ego-replay-frames 60
#
#   # Pass arbitrary extra flags directly to the evaluator
#   run_eval_ultimate.sh ... -- --some-experimental-flag value
# ==============================================================================

PYTHON=/opt/conda/envs/mdsn/bin/python
EVALUATOR=/root/MetaBench/bridgesim/evaluation/unified_evaluator.py

# ── Defaults ──────────────────────────────────────────────────────────────────
TRAFFIC_MODE="log_replay"
EGO_REPLAY_FRAMES="20"
EVAL_MODE="closed_loop"
CONTROLLER="pure_pursuit"
BEV_SAMPLE_STEPS="10"

# ── Argument parsing ──────────────────────────────────────────────────────────
EXTRA_ARGS=()   # collects unknown flags + everything after --

while [[ $# -gt 0 ]]; do
    case "$1" in
        # ── Required ──
        --model-type)              MODEL_TYPE="$2";              shift 2 ;;
        --checkpoint)              CHECKPOINT="$2";              shift 2 ;;
        --scenario-base-path)      SCENARIO_BASE_PATH="$2";      shift 2 ;;
        --output-dir)              OUTPUT_DIR="$2";              shift 2 ;;
        --replan-rate)             REPLAN_RATE="$2";             shift 2 ;;
        --eval-frames)             EVAL_FRAMES="$2";             shift 2 ;;
        --scene-list)              SCENE_LIST_FILE="$2";         shift 2 ;;

        # ── Config / anchor ──
        --config-or-anchor)        CONFIG_OR_ANCHOR="$2";        shift 2 ;;

        # ── Eval behaviour ──
        --traffic-mode)            TRAFFIC_MODE="$2";            shift 2 ;;
        --ego-replay-frames)       EGO_REPLAY_FRAMES="$2";       shift 2 ;;
        --eval-mode)               EVAL_MODE="$2";               shift 2 ;;
        --controller)              CONTROLLER="$2";              shift 2 ;;

        # ── Scorer ──
        --trajectory-scorer)       TRAJECTORY_SCORER="$2";       shift 2 ;;
        --num-groups)              NUM_GROUPS="$2";              shift 2 ;;
        --v2-scorer-checkpoint)    V2_SCORER_CHECKPOINT="$2";    shift 2 ;;

        # ── BEV calibrator ──
        --bev-calibrator-checkpoint) BEV_CALIBRATOR_CHECKPOINT="$2"; shift 2 ;;
        --bev-sample-steps)        BEV_SAMPLE_STEPS="$2";        shift 2 ;;

        # ── Image source ──
        --image-source)            IMAGE_SOURCE="$2";            shift 2 ;;

        # ── Scoring window ──
        --score-start-frame)       SCORE_START_FRAME="$2";       shift 2 ;;

        # ── End-of-options sentinel: everything after goes to Python ──
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;

        # ── Unknown flag: forward to Python ──
        --*)
            # Peek at next token; if it looks like a value (not a flag) consume it
            if [[ $# -ge 2 && "$2" != --* ]]; then
                EXTRA_ARGS+=("$1" "$2")
                shift 2
            else
                EXTRA_ARGS+=("$1")
                shift
            fi
            ;;

        *)
            echo "ERROR: Unexpected argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Validate required args ────────────────────────────────────────────────────
missing=()
[[ -z "${MODEL_TYPE:-}"         ]] && missing+=(--model-type)
[[ -z "${CHECKPOINT:-}"         ]] && missing+=(--checkpoint)
[[ -z "${SCENARIO_BASE_PATH:-}" ]] && missing+=(--scenario-base-path)
[[ -z "${OUTPUT_DIR:-}"         ]] && missing+=(--output-dir)
[[ -z "${REPLAN_RATE:-}"        ]] && missing+=(--replan-rate)
[[ -z "${EVAL_FRAMES:-}"        ]] && missing+=(--eval-frames)
[[ -z "${SCENE_LIST_FILE:-}"    ]] && missing+=(--scene-list)

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required argument(s): ${missing[*]}" >&2
    echo "Run with --help or read the header of this script for usage." >&2
    exit 1
fi

# ── Build config/anchor fragment ──────────────────────────────────────────────
CONFIG_ANCHOR_ARGS=()
if [[ -n "${CONFIG_OR_ANCHOR:-}" ]]; then
    case "$CONFIG_OR_ANCHOR" in
        *.py) CONFIG_ANCHOR_ARGS=(--config "$CONFIG_OR_ANCHOR") ;;
        *)    CONFIG_ANCHOR_ARGS=(--plan-anchor-path "$CONFIG_OR_ANCHOR") ;;
    esac
fi

# ── Build scorer fragment ─────────────────────────────────────────────────────
SCORER_ARGS=()
if [[ -n "${TRAJECTORY_SCORER:-}" ]]; then
    SCORER_ARGS+=(--trajectory-scorer "$TRAJECTORY_SCORER")
    [[ -n "${NUM_GROUPS:-}"           ]] && SCORER_ARGS+=(--num-groups "$NUM_GROUPS")
    [[ -n "${V2_SCORER_CHECKPOINT:-}" ]] && SCORER_ARGS+=(--v2-scorer-checkpoint "$V2_SCORER_CHECKPOINT")
fi

# ── Build BEV calibrator fragment ─────────────────────────────────────────────
BEV_ARGS=()
if [[ -n "${BEV_CALIBRATOR_CHECKPOINT:-}" ]]; then
    BEV_ARGS+=(
        --enable-bev-calibrator
        --bev-calibrator-checkpoint "$BEV_CALIBRATOR_CHECKPOINT"
        --bev-sample-steps "$BEV_SAMPLE_STEPS"
    )
fi

# ── Build image-source fragment ───────────────────────────────────────────────
IMAGE_ARGS=()
[[ -n "${IMAGE_SOURCE:-}" ]] && IMAGE_ARGS=(--image-source "$IMAGE_SOURCE")

# ── Build score-start-frame fragment ─────────────────────────────────────────
SCORE_FRAME_ARGS=()
[[ -n "${SCORE_START_FRAME:-}" ]] && SCORE_FRAME_ARGS=(--score-start-frame "$SCORE_START_FRAME")

# ── Summary ───────────────────────────────────────────────────────────────────
echo "========================================"
echo "  run_eval_ultimate.sh"
echo "========================================"
echo "  model-type       : $MODEL_TYPE"
echo "  checkpoint       : $CHECKPOINT"
echo "  scenario-base    : $SCENARIO_BASE_PATH"
echo "  output-dir       : $OUTPUT_DIR"
echo "  scene-list       : $SCENE_LIST_FILE"
echo "  traffic-mode     : $TRAFFIC_MODE"
echo "  ego-replay-frames: $EGO_REPLAY_FRAMES"
echo "  replan-rate      : $REPLAN_RATE"
echo "  eval-frames      : $EVAL_FRAMES"
[[ -n "${CONFIG_OR_ANCHOR:-}"          ]] && echo "  config/anchor    : $CONFIG_OR_ANCHOR"
[[ -n "${TRAJECTORY_SCORER:-}"         ]] && echo "  scorer           : $TRAJECTORY_SCORER"
[[ -n "${NUM_GROUPS:-}"                ]] && echo "  num-groups       : $NUM_GROUPS"
[[ -n "${V2_SCORER_CHECKPOINT:-}"      ]] && echo "  v2-scorer-ckpt   : $V2_SCORER_CHECKPOINT"
[[ -n "${BEV_CALIBRATOR_CHECKPOINT:-}" ]] && echo "  bev-cal-ckpt     : $BEV_CALIBRATOR_CHECKPOINT (steps=$BEV_SAMPLE_STEPS)"
[[ -n "${IMAGE_SOURCE:-}"              ]] && echo "  image-source     : $IMAGE_SOURCE"
[[ -n "${SCORE_START_FRAME:-}"         ]] && echo "  score-start-frame: $SCORE_START_FRAME"
[[ ${#EXTRA_ARGS[@]} -gt 0             ]] && echo "  extra args       : ${EXTRA_ARGS[*]}"
echo "========================================"

# ── Main loop ─────────────────────────────────────────────────────────────────
while read -r scene_id || [[ -n "$scene_id" ]]; do
    [[ -z "$scene_id" ]] && continue

    echo "Processing: $scene_id"
    "$PYTHON" "$EVALUATOR" \
        --model-type    "$MODEL_TYPE" \
        --checkpoint    "$CHECKPOINT" \
        "${CONFIG_ANCHOR_ARGS[@]}" \
        --scenario-path "${SCENARIO_BASE_PATH}/${scene_id}" \
        --traffic-mode  "$TRAFFIC_MODE" \
        --output-dir    "$OUTPUT_DIR" \
        --eval-mode     "$EVAL_MODE" \
        --controller    "$CONTROLLER" \
        --replan-rate   "$REPLAN_RATE" \
        --ego-replay-frames "$EGO_REPLAY_FRAMES" \
        --eval-frames   "$EVAL_FRAMES" \
        "${SCORER_ARGS[@]}" \
        "${BEV_ARGS[@]}" \
        "${IMAGE_ARGS[@]}" \
        "${SCORE_FRAME_ARGS[@]}" \
        "${EXTRA_ARGS[@]}"

done < <(tr -d '\r' < "$SCENE_LIST_FILE")

echo "All scenes processed."
