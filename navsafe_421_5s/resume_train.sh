#!/usr/bin/env bash
# resume_train.sh — submit ONLY the navhard scenes that still need training, i.e.
# no last.usdz on CephFS yet AND no existing job. Ground truth = the usdz files,
# so it's idempotent: re-run any time, it never re-does a finished scene and never
# kills a running one.
#
# Gated by the Nautilus util-policy: it PROBES with `--dry-run=server` (creates
# nothing, does NOT reset the cooldown) and only does real submits when the policy
# is open, backing off to probe-mode if it re-denies. Keeps ~TARGET jobs in flight
# so the Pending pile never rebuilds (which is what trips the util-policy).
#
# Usage:   ./resume_train.sh              # TARGET=85 (10 nodes)
#          TARGET=60 ./resume_train.sh    # override in-flight target
#          KEEP_PENDING=1 ./resume_train.sh   # don't delete current pending jobs
set -uo pipefail
cd "$(dirname "$0")"
NS=cogrob
L="app=navhard421-5s,stage=train"
TARGET=${TARGET:-85}
LIST=train_list.txt          # all 839 split scene-ids
REM=remaining_train.txt      # written each pass: scenes still needing a job

[ -f "$LIST" ] || { echo "!! $LIST missing"; exit 1; }
[ -d rendered/train ] || { echo "!! rendered/train/ missing — run: DRYRUN=1 ONLY=$LIST ./run_stage.sh train"; exit 1; }

# 0) delete stuck Pending jobs (stale specs) unless told to keep them
if [ "${KEEP_PENDING:-0}" != "1" ]; then
  kubectl get pods -n "$NS" -l "$L" --field-selector=status.phase=Pending \
    -o jsonpath='{range .items[*]}{.metadata.labels.job-name}{"\n"}{end}' 2>/dev/null \
    | sort -u | grep . | xargs -r -n20 kubectl delete job -n "$NS" >/dev/null 2>&1
  echo "[resume] deleted current Pending jobs"
fi

# scenes that already have last.usdz on CephFS (queried via a running train pod,
# which mounts /avl-west; the Mac can't read CephFS directly)
usdz_done() {
  local pod
  pod=$(kubectl get pods -n "$NS" -l "$L" --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pod" ] && return 0
  kubectl exec -n "$NS" "$pod" -- bash -c \
    'for f in /avl-west/navhard421-website-5s/*/output_5cam/*/artifacts/last.usdz; do [ -f "$f" ] && echo "$f"; done' 2>/dev/null \
    | sed -E 's#.*/navhard421-website-5s/([^/]+)/output_5cam.*#\1#'
}

while :; do
  # remaining = LIST − done − RUNNING.  "done" = has last.usdz on CephFS (ground
  # truth) OR a Succeeded job (equivalent, and a fallback when no pod is up to query
  # CephFS). Failed/terminal jobs are NOT skipped: no usdz => still need training.
  done_l=$(usdz_done | sort -u)
  succ_l=$(kubectl get jobs -n "$NS" -l "$L" \
           -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
           | sed 's/nav5s-train-//' | sort -u)
  run_l=$(kubectl get pods -n "$NS" -l "$L" --field-selector=status.phase=Running \
          -o jsonpath='{range .items[*]}{.metadata.labels.job-name}{"\n"}{end}' 2>/dev/null \
          | sed 's/nav5s-train-//' | sort -u)
  comm -23 <(sort -u "$LIST") <(printf '%s\n%s\n%s\n' "$done_l" "$succ_l" "$run_l" | sort -u) | grep . > "$REM" || true
  rc=$(grep -c . "$REM" 2>/dev/null || echo 0)
  [ "$rc" -eq 0 ] && { echo "[resume] done — every scene has a usdz or is running"; break; }

  # gate: probe the util-policy without creating anything
  probe=$(head -1 "$REM")
  if ! kubectl apply --dry-run=server -f "rendered/train/${probe}.yaml" 2>&1 | grep -qi created; then
    echo "$(date -u +%H:%M) [resume] util-policy cooling, $rc remaining — waiting 10m (not submitting)"
    sleep 600; continue
  fi

  # policy open: top up to TARGET in-flight
  run=$(kubectl get pods -n "$NS" -l "$L" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  pend=$(kubectl get pods -n "$NS" -l "$L" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
  slots=$(( TARGET - run - pend ))
  n=0
  if [ "$slots" -gt 0 ]; then
    while IFS= read -r C; do
      # clear any stale/failed job object of the same name (terminal pods already
      # gone -> util-neutral), then create fresh so failed scenes get retried
      kubectl delete job -n "$NS" "nav5s-train-${C}" --ignore-not-found --wait=false >/dev/null 2>&1
      out=$(kubectl apply -f "rendered/train/${C}.yaml" 2>&1)
      case "$out" in
        *created*) n=$((n+1));;
        *"utilization is too low"*) echo "[resume] re-denied mid-pass — back to probing"; break;;
      esac
      [ "$n" -ge "$slots" ] && break
    done < "$REM"
  fi
  echo "$(date -u +%H:%M) [resume] +$n submitted (run=$run pend=$pend remaining=$rc target=$TARGET)"
  sleep 180
done
