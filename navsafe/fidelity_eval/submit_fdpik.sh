#!/usr/bin/env bash
# submit_fdpik.sh — one job per (agent x variation) cell of the FDpi^k matrix.
#
# Panel = the paper's five: drivor_f0 dd_front ltf rap sd. RAP is D=1280 and
# SparseDriveV2 D=256, so both need N >> 310 to be estimable — which is exactly why
# this stage waits for the full-corpus render rather than reusing the 10-scenario one.
#
#   ./submit_fdpik.sh                                   # all cells still missing
#   AGENTS="rap sd" ./submit_fdpik.sh                    # just the two added last
#   VARIATIONS="nurec_cmp" ./submit_fdpik.sh              # one side only
#   DRYRUN=1 ./submit_fdpik.sh
set -uo pipefail
cd "$(dirname "$0")"
NS="${NS:-cogrob}"; POD="${POD:-horuan-nexussim}"
# All five of the paper's panel. The two that used to be skipped are in:
#
#   * RAP's D=1280 needed N >> 310 to be estimable, and the full-corpus render
#     gives it 4164 tokens.
#   * SparseDriveV2's deformable-aggregation CUDA extension is built and matches
#     this env (cpython-310 .so beside its source).
#
# Both were verified to build, load their checkpoint and move to GPU. What is
# NOT verified by that is memory under load: RAP is a DINO backbone at 1280-d
# taking 1920x1080 on a 24 GB 3090. If a cell OOMs it is that, not the setup.
# SparseDriveV2 also silently produces wrong features if its navsim-v1 metric
# config is not honoured, so check `feature_dim` and `n_intersect` in its output
# json rather than trusting a zero exit.
AGENTS="${AGENTS:-drivor_f0 dd_front ltf rap sd}"
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
  # k8s object names are RFC 1123: no underscores. The agent and variation
  # themselves keep theirs -- they are arguments to the eval script, not names.
  SHARD=$(printf '%s' "${V}-${A}-${RUNID}" | tr '_' '-')
  sed -e "s/__SHARD__/$SHARD/g" -e "s/__AGENT__/$A/g" -e "s/__VARIATION__/$V/g" \
      templates/fdpik.yaml > "$OUT/$SHARD.yaml"
  echo "$OUT/$SHARD.yaml" >> "$NEW"; N=$((N+1))
done; done
echo "[fdpik] $N cell(s) to submit"
[ "$N" -eq 0 ] && { echo "[fdpik] MATRIX COMPLETE."; rm -f "$DONE" "$NEW"; exit 0; }
if [ -n "${DRYRUN:-}" ]; then echo "[fdpik] DRYRUN: see $OUT/"; rm -f "$DONE" "$NEW"; exit 0; fi
# Count what actually landed. `xargs kubectl apply` reports its own failures on
# stderr and keeps going, so the old unconditional "submitted N" printed a
# success line for a run in which every single apply had been rejected.
OK=0; FAIL=0
while read -r Y; do
  if kubectl apply -f "$Y" >/dev/null 2>&1; then OK=$((OK+1)); else
    FAIL=$((FAIL+1)); echo "  !! apply failed: $(basename "$Y")"; kubectl apply -f "$Y" 2>&1 | tail -1
  fi
done < "$NEW"
echo "[fdpik] submitted $OK of $N cell(s); $FAIL failed.  watch: ./status.sh"
[ "$FAIL" -eq 0 ] || { rm -f "$DONE" "$NEW"; exit 1; }
rm -f "$DONE" "$NEW"
