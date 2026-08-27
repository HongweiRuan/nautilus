#!/usr/bin/env bash
# submit_fdpik.sh — one job per (agent x variation) cell of the FDpi^k matrix.
#
# Panel = the paper's five: drivor_f0 dd_front ltf rap sd. RAP is D=1280 and
# SparseDriveV2 D=256, so both need N >> 310 to be estimable — which is exactly why
# this stage waits for the full-corpus render rather than reusing the 10-scenario one.
#
#   ./submit_fdpik.sh                                   # all cells still missing
#   AGENTS="drivor_f0 dd_front ltf" ./submit_fdpik.sh    # skip the two that need CUDA exts
#   VARIATIONS="nurec_cmp" ./submit_fdpik.sh              # one side only
#   DRYRUN=1 ./submit_fdpik.sh
set -uo pipefail
cd "$(dirname "$0")"
NS="${NS:-cogrob}"; POD="${POD:-horuan-nexussim}"
# Three agents, not the paper's five. RAP and SparseDriveV2 build and import fine
# but have never been run end to end here, and both carry runtime risk worth not
# taking mid-batch: RAP is a DINOv3 backbone at 1280-d being fed 1920x1080 on a 24 GB
# 3090, and SparseDriveV2 silently produces wrong features if its navsim-v1 metric
# config is not honoured. FDpi^k is a mean over an arbitrary panel, so three is a
# valid metric -- just not comparable to the paper's five-policy cells.
AGENTS="${AGENTS:-drivor_f0 dd_front ltf}"
VARIATIONS="${VARIATIONS:-nurec_cmp drivearena_cmp}"
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"
OUT="rendered/fdpik"; mkdir -p "$OUT"
E=/avl-west/drivearena_bench/unified_evaluator/exp/navsim_fd

# which cells already have their FD json? (one exec — refuse to guess if it fails)
DONE=$(mktemp)
# Same sentinel as submit_stage.sh: an empty glob means "no cell scored yet", not
# "pod is dead", and only the latter may block a submission.
kubectl exec -n "$NS" "$POD" -- bash -lc \
  "ls $E/*/*/fd_*_vs_original.json 2>/dev/null; echo __PROBE_OK__" > "$DONE".raw 2>/dev/null
if ! grep -q __PROBE_OK__ "$DONE".raw; then
  echo "!! cannot read CephFS through pod '$POD' — refusing to submit."; rm -f "$DONE"*; exit 1
fi
grep -v __PROBE_OK__ "$DONE".raw \
  | sed -E 's#.*/navsim_fd/([^/]+)/([^/]+)/fd_.*#\1 \2#' | grep . | sort -u > "$DONE" || true
rm -f "$DONE".raw

N=0; NEW=$(mktemp)
for V in $VARIATIONS; do for A in $AGENTS; do
  grep -qx "$V $A" "$DONE" && { echo "  skip $V/$A (done)"; continue; }
  SHARD="${V}-${A}-${RUNID}"
  sed -e "s/__SHARD__/$SHARD/g" -e "s/__AGENT__/$A/g" -e "s/__VARIATION__/$V/g" \
      templates/fdpik.yaml > "$OUT/$SHARD.yaml"
  echo "$OUT/$SHARD.yaml" >> "$NEW"; N=$((N+1))
done; done
echo "[fdpik] $N cell(s) to submit"
[ "$N" -eq 0 ] && { echo "[fdpik] MATRIX COMPLETE."; rm -f "$DONE" "$NEW"; exit 0; }
if [ -n "${DRYRUN:-}" ]; then echo "[fdpik] DRYRUN: see $OUT/"; rm -f "$DONE" "$NEW"; exit 0; fi
xargs -n1 kubectl apply -f < "$NEW"
echo "[fdpik] submitted $N cell(s).  watch: ./status.sh"
rm -f "$DONE" "$NEW"
