#!/usr/bin/env bash
# Submit the NavSafe model-zoo sweep, gently.
#
# Idempotent: re-run it to top the fleet back up. A worker whose Job already
# exists and is active or succeeded is left alone; a failed one is replaced; a
# pod killed by the 6 h deadline is retried by its own Job and resumes from the
# cells already scored.
#
# All workers go out in ONE pass, as fast as kubectl will take them. The
# util-policy webhook (job.nrp-nautilus.io) reacts to a burst only *after* the
# fact, so a fleet submitted quickly is admitted; and once a Job exists, a later
# cooldown does not touch it — it blocks new submissions, not running work.
# Pacing the submissions would only widen the window in which the webhook can
# catch the tail of the fleet.
#
#   ./submit_eval.sh                 # WORKERS=30, SEEDS=1
#   SEEDS="2 3" ./submit_eval.sh     # the remaining seeds, same layout
#   WORKERS=8 ./submit_eval.sh
set -uo pipefail
cd "$(dirname "$0")"

NS=${NS:-cogrob}
POD=${POD:-horuan-nexussim}          # mounts /avl-west; used only to read state
WORKERS=${WORKERS:-30}
SEEDS=${SEEDS:-1}
# A campaign is a root (dataset/ + outputs/), a model list, a Job name prefix and
# its own ConfigMap. Defaulting to the model-zoo sweep keeps `./submit_eval.sh`
# meaning exactly what it did; a second campaign sets these and shares
# everything else, so there is one driver and one template to keep correct.
ROOT=${ROOT:-/avl-west/navsafe_eval}
JOB_PREFIX=${JOB_PREFIX:-navsafe-eval}
CFGMAP=${CFGMAP:-navsafe-eval-cfg}
MODELS=${MODELS:-models.tsv}
AH_REPLACE=${AH_REPLACE:-0}
# Paired runs (both conditions per cell) and per-frame visualisation. Both
# default off so existing campaigns are unchanged.
AH_PAIR=${AH_PAIR:-0}
VIS=${VIS:-0}
# Which bundle set. Defaults to $ROOT/dataset; overridden when a campaign runs
# a subset (e.g. only the scenarios that scored in an earlier sweep).
DATASET=${DATASET:-$ROOT/dataset}
# Per-cell wall-clock ceiling. 45m fits a scored-only cell; per-frame
# visualisation adds ~40%, so a vis campaign raises it.
CELL_TIMEOUT=${CELL_TIMEOUT:-45m}
NEXUSSIM_OVERLAY=${NEXUSSIM_OVERLAY:-0}
OUTROOT=${OUTROOT:-$ROOT/outputs}
ZOO=${ZOO:-$ROOT/model_zoo}
NODES=${NODES:-ry-gpu-05.sdsc.optiputer.net, ry-gpu-06.sdsc.optiputer.net, ry-gpu-07.sdsc.optiputer.net, ry-gpu-11.sdsc.optiputer.net, ry-gpu-12.sdsc.optiputer.net, ry-gpu-13.sdsc.optiputer.net, ry-gpu-14.sdsc.optiputer.net}
SKIP_ADAPTER_CHECK=${SKIP_ADAPTER_CHECK:-0}

# BSD seq (this is driven from a Mac) prints "0" and "-1" for `seq 0 -1`, where
# GNU seq prints nothing — so WORKERS=0 submitted a worker w00 that would divide
# by zero and a job literally named navsafe-eval-w-1. Reject the input instead
# of trusting the loop bound.
case "$WORKERS" in ''|*[!0-9]*) echo "!! WORKERS must be a positive integer, got '$WORKERS'"; exit 1;; esac
[ "$WORKERS" -ge 1 ] || { echo "!! WORKERS must be >= 1, got $WORKERS"; exit 1; }

# ── refuse to spend 60 GPUs on a model that cannot load ──────────────────────
if [ "$SKIP_ADAPTER_CHECK" = "1" ]; then
  echo "=== adapter readiness: skipped ==="
else
  echo "=== adapter readiness ==="
  ./check_adapters.sh || { echo "!! not every row is runnable — fix that first"; exit 1; }
fi

# ── the commit the whole campaign is evaluated at ────────────────────────────
SHA=${NEXUSSIM_SHA:-$(kubectl exec -n "$NS" "$POD" -- git -C /hugsim-storage/NexusSim rev-parse HEAD 2>/dev/null | tr -d '\r\n')}
[ -n "$SHA" ] || { echo "!! could not resolve a NexusSim commit"; exit 1; }
echo "=== code: $SHA ==="

# ── ship the driver as a ConfigMap ───────────────────────────────────────────
# Not copied onto the PVC: a file on CephFS outlives the manifest that describes
# it, and a worker reading a driver someone edited between passes is the kind of
# thing that makes half a campaign incomparable to the other half.
kubectl create configmap "$CFGMAP" -n "$NS" \
  --from-file=run_worker.sh=run_worker.sh \
  --from-file=models.tsv="$MODELS" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null || exit 1
echo "=== configmap $CFGMAP updated (models: $MODELS) ==="

# ── record what this campaign is ─────────────────────────────────────────────
kubectl exec -n "$NS" "$POD" -- bash -c "
  mkdir -p $OUTROOT
  { echo 'date: $(date -u +%Y-%m-%dT%H:%M:%SZ)'
    echo 'nexussim_sha: $SHA'
    echo 'workers: $WORKERS'
    echo 'seeds: \"$SEEDS\"'
    echo 'scenarios: '\$(ls $ROOT/dataset | wc -l)
    echo 'ah_replace: $AH_REPLACE'
    echo 'renderer: serve-grpc --cache-size 4 --enable-harmonizer --enable-editing-actors --renderer default'
    echo 'episode: semi_reactive traffic, --ego-replay-frames 20, --terminate-on-collision,'
    echo '         --execution-mode controller --controller lqr, --replan-rate 5,'
    echo '         --eval-frames 600 (= 20 warm-up + 600 scored = the 60 s ceiling),'
    echo '         no --enable-vis'
  } >> $OUTROOT/campaign.yaml" 2>/dev/null

# ── submit, all at once ──────────────────────────────────────────────────────
submitted=0; skipped=0
for i in $(seq 0 $((WORKERS-1))); do
  W=$(printf 'w%02d' "$i")
  JOB="$JOB_PREFIX-$W"
  if kubectl get job -n "$NS" "$JOB" >/dev/null 2>&1; then
    read -r active succ fail < <(kubectl get job -n "$NS" "$JOB" \
      -o jsonpath='{.status.active}{" "}{.status.succeeded}{" "}{.status.failed}' 2>/dev/null)
    # A Job whose status has not been populated yet was created moments ago —
    # leave it alone, or a re-run deletes the fleet it just submitted.
    if [ -z "${active:-}" ] && [ -z "${succ:-}" ] && [ -z "${fail:-}" ]; then skipped=$((skipped+1)); continue; fi
    if [ -n "${active:-}" ] && [ "${active}" != "0" ]; then skipped=$((skipped+1)); continue; fi
    if [ "${succ:-0}" = "1" ]; then skipped=$((skipped+1)); continue; fi
    echo "[$W] previous job exhausted its retries — replacing"
    kubectl delete job -n "$NS" "$JOB" --wait=true >/dev/null 2>&1
  fi

  sed -e "s|__W__|$W|g" -e "s|__WIDX__|$i|g" -e "s|__WORKERS__|$WORKERS|g" \
      -e "s|__SEEDS__|$SEEDS|g" -e "s|__SHA__|$SHA|g" \
      -e "s|__ROOT__|$ROOT|g" -e "s|__AHREPLACE__|$AH_REPLACE|g" \
      -e "s|__JOBPREFIX__|$JOB_PREFIX|g" -e "s|__CFGMAP__|$CFGMAP|g" \
      -e "s|__OUTROOT__|$OUTROOT|g" -e "s|__ZOO__|$ZOO|g" \
      -e "s|__NODES__|$NODES|g" -e "s|__OVERLAY__|$NEXUSSIM_OVERLAY|g" \
      -e "s|__AHPAIR__|$AH_PAIR|g" -e "s|__VIS__|$VIS|g" \
      -e "s|__DATASET__|$DATASET|g" \
      -e "s|__CELLTIMEOUT__|$CELL_TIMEOUT|g" \
      templates/eval_worker.yaml > "rendered/$JOB_PREFIX-$W.yaml"
  out=$(kubectl apply -f "rendered/$JOB_PREFIX-$W.yaml" 2>&1)
  echo "[$W] $out"
  case "$out" in
    *created*|*configured*) submitted=$((submitted+1));;
    *"utilization is too low"*)
      # Only reachable if a cooldown was ALREADY in force when this run started.
      # The workers admitted before this point keep running; re-run the script
      # once the cooldown expires and it will fill in the rest.
      echo; echo "=== UTIL-POLICY DENIED at $W after $submitted submitted ==="
      echo "    the $submitted already admitted are unaffected and will run."
      echo "    stop submitting, let the cooldown expire, then re-run this script."
      echo "    probe without creating anything:  kubectl apply --dry-run=server -f rendered/$JOB_PREFIX-$W.yaml"
      exit 2;;
    *) echo "    (unrecognised result — stopping)"; exit 3;;
  esac
done
echo "=== submitted $submitted, left alone $skipped, of $WORKERS workers ==="

[ -x ./status.sh ] && JOB_PREFIX="$JOB_PREFIX" ROOT="$ROOT" ./status.sh || true
