#!/bin/bash
# Submit one fleet of the hand-off perturbation sweep.
#
#   ./bash_offset_eval.sh addon il il_edit   the four models the first sweep missed
#   ./bash_offset_eval.sh plain edit     the two four-model fleets
#   ./bash_offset_eval.sh                all four
#
# Everything a job needs is in job_offset_eval.yaml; this only fills in the
# per-fleet values and loops the worker index, the way
# bridgesim/navhard_idm/eval_navhard_cali_idm does.
#
# Run bin/stage.sh first, once: it copies run_worker.sh and the model/scenario
# lists onto the PVC, where the jobs read them from.
set -uo pipefail
cd "$(dirname "$0")"
TOOLING=/avl-west/runs/20260905-handoff-perturb-demo/tooling

# fleet        workers  gpus  mem req/limit   models              scenarios
#
# plain   46 scenarios that insert nothing -- one card is correct there, an LRU
#         eviction costs a reload and nothing else.
# edit     8 scenarios whose recipe INSERTS an actor. The insert is an
#         edit_assets mutation of the render server's loaded copy of each of the
#         scenario's four reconstructions, so all four must stay resident:
#         --cache-size 4, which needs the renderer to have a card to itself.
#         See README.md.
# simwam  SimWAM-RL, 12.6 GiB of its own -> two cards whatever the scenario.
#
# The three fleets that add the models the first sweep missed:
#
# addon   simwam_base, mtdrive_sft, mtdrive_mtgrpo -- each needs a card to
#         itself, so two cards, all 54 scenarios.
# il      recogdrive_il on the 46 non-inserting scenarios. At 2B it shares a
#         card with the renderer, and that is not just tidiness: ry-gpu-05 is
#         NotReady and ry-gpu-08 serves ONE-card pods only, so a two-card pod can
#         reach 40 of the 48 GPUs and ry-gpu-08's are unreachable to it. This
#         fleet runs on capacity the two-card fleets cannot use at all.
# il_edit recogdrive_il on the 8 inserting scenarios, which need --cache-size 4
#         and therefore a second card whatever the model.
fleet_cfg() {
  case "$1" in
    plain)  WORKERS=8;  GPUS=1; MEM_REQ=36Gi; MEM_LIM=43Gi
            MODELS_TSV=$TOOLING/models.tsv;        SELECTION=$TOOLING/selection_plain.json ;;
    edit)   WORKERS=8;  GPUS=2; MEM_REQ=36Gi; MEM_LIM=43Gi
            MODELS_TSV=$TOOLING/models.tsv;        SELECTION=$TOOLING/selection_edit.json ;;
    simwam) WORKERS=12; GPUS=2; MEM_REQ=76Gi; MEM_LIM=91Gi
            MODELS_TSV=$TOOLING/models_simwam.tsv; SELECTION=$TOOLING/selection.json ;;
    # addon + il_edit = 16x2 + 4x2 = 40 GPUs, which is every GPU a two-card pod
    # can reach. il takes the one-card-only capacity on top of that.
    addon)   WORKERS=16; GPUS=2; MEM_REQ=76Gi; MEM_LIM=91Gi
             MODELS_TSV=$TOOLING/models_addon.tsv; SELECTION=$TOOLING/selection.json ;;
    il)      WORKERS=8;  GPUS=1; MEM_REQ=36Gi; MEM_LIM=43Gi
             MODELS_TSV=$TOOLING/models_il.tsv;    SELECTION=$TOOLING/selection_plain.json ;;
    il_edit) WORKERS=4;  GPUS=2; MEM_REQ=36Gi; MEM_LIM=43Gi
             MODELS_TSV=$TOOLING/models_il.tsv;    SELECTION=$TOOLING/selection_edit.json ;;
    *) echo "unknown fleet: $1 (plain|edit|simwam|addon|il|il_edit)" >&2; return 2 ;;
  esac
}

command -v envsubst >/dev/null || { echo "need envsubst (brew install gettext)"; exit 1; }

# Name the variables explicitly. Bare `envsubst` substitutes EVERY $VAR in the
# file, including any the container's own shell script defines -- those come out
# as the empty string, because they are unset HERE. That is exactly how the
# first submission shipped `ls /run_worker.sh` and crash-looped 24 jobs.
SUBST='${FLEET} ${IDX} ${IDX_N} ${WORKERS} ${GPUS} ${MEM_REQ} ${MEM_LIM} ${MODELS_TSV} ${SELECTION}'

for FLEET in "${@:-plain edit simwam addon il il_edit}"; do
  fleet_cfg "$FLEET" || exit 2
  export FLEET WORKERS GPUS MEM_REQ MEM_LIM MODELS_TSV SELECTION
  echo "=== $FLEET: $WORKERS workers x ${GPUS} GPU, $MODELS_TSV, $(basename $SELECTION) ==="
  for i in $(seq 0 $((WORKERS - 1))); do
    IDX=$(printf %02d "$i")   # w00, w01, ... -- `seq -w` pads to the width of
    IDX_N=$i                  # its LARGEST argument, which is not what we want
    export IDX IDX_N
    if [ "$GPUS" -ge 2 ]; then
      # Two cards: drop ry-gpu-08, whose plugin fails multi-GPU allocation.
      # Only the LIST ENTRY, not the comment that explains why: a bare
      # grep -v would silently eat the explanation too.
      envsubst "$SUBST" < job_offset_eval.yaml | grep -v '^ *- ry-gpu-08' > /tmp/oe-$$.yaml
    else
      envsubst "$SUBST" < job_offset_eval.yaml > /tmp/oe-$$.yaml
    fi
    # RETRY, do not fire and forget. The nrp-nautilus admission webhook refuses
    # on the account's GPU utilisation and comes and goes on a ~20 min cycle; a
    # plain `kubectl apply` would just print the refusal and the loop would move
    # on, leaving a hole in the fleet that nothing reports later.
    until out=$(kubectl apply -f /tmp/oe-$$.yaml 2>&1); do
      case "$out" in
        *"already exists"*) echo "  navsafe-$FLEET-w$IDX exists, skipping"; break ;;
        *"utilization is too low"*)
          echo "  webhook refusing at navsafe-$FLEET-w$IDX — retry in 5 min ($(date -u +%H:%MZ))"
          sleep 300 ;;
        *) echo "  FAILED navsafe-$FLEET-w$IDX: $(echo "$out" | tail -1)"; break ;;
      esac
    done
    case "$out" in *created*|*configured*) echo "  $out" ;; esac
    rm -f /tmp/oe-$$.yaml
  done
done
