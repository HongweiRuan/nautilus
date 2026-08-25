#!/usr/bin/env bash
# Where the sweep is: Job health from Kubernetes, cell completion from the PVC.
#
# Two sources on purpose. Job status is one fast call and has no partial-write
# race, so it is what says whether the fleet is alive; but a Job succeeds when
# its worker finishes its slice, failed cells included, so the per-cell count has
# to come from the artifacts. A cell counts as done only when eval_py123d wrote
# its DONE line AND a navsafe_metrics.json exists — with --enable-vis off there
# are no frames to count, and a killed episode leaves a log either way.
set -uo pipefail
cd "$(dirname "$0")"
NS=${NS:-cogrob}
POD=${POD:-horuan-nexussim}
SEEDS=${SEEDS:-1}
ROOT=/avl-west/navsafe_eval

kubectl cp models.tsv "$NS/$POD:/tmp/models.tsv" >/dev/null 2>&1

echo "=== jobs ==="
kubectl get jobs -n "$NS" -l app=navsafe-eval \
  -o custom-columns='JOB:.metadata.name,ACTIVE:.status.active,OK:.status.succeeded,FAILED:.status.failed' 2>/dev/null
echo
echo "=== pods ==="
kubectl get pods -n "$NS" -l app=navsafe-eval \
  -o custom-columns='POD:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,AGE:.metadata.creationTimestamp' 2>/dev/null
echo
echo "=== cells (done / total per model x seed) ==="
kubectl exec -n "$NS" "$POD" -- bash -c "
  N=\$(ls $ROOT/dataset | wc -l)
  printf '%-20s %-6s %8s %8s %8s\n' model seed done failed pending
  for M in \$(grep -v '^\s*#' /tmp/models.tsv 2>/dev/null | awk 'NF{print \$1}'); do
    for S in $SEEDS; do
      D=\$(ls $ROOT/outputs/\$M/seed\$S/*/navsafe_metrics.json 2>/dev/null | wc -l)
      L=\$(ls $ROOT/outputs/\$M/seed\$S/*.log 2>/dev/null | grep -vc '\.serve\.log$')
      F=\$(( L - D )); [ \$F -lt 0 ] && F=0
      printf '%-20s %-6s %8s %8s %8s\n' \$M \$S \$D \$F \$(( N - D - F ))
    done
  done" 2>/dev/null
