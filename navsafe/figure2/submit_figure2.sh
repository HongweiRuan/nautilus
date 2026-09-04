#!/bin/bash
# One Job per scenario in scenarios.txt. Re-running is safe: a Job whose name
# already exists is replaced, and a scenario already carrying a .done is
# skipped unless --force.
#
# The worker script goes in as a ConfigMap rather than a here-string inside the
# Job: a 200-line shell program embedded in YAML is not reviewable, and every
# edit to it would otherwise rewrite sixteen manifests.
set -eo pipefail
cd "$(dirname "$0")"

OUTROOT=${OUTROOT:-/avl-west/runs/20260902-paper-figure2-drivor}
REPLAY=${REPLAY:-20}
EVALF=${EVALF:-180}
NS=cogrob
FORCE=""
[ "$1" = --force ] && { FORCE=1; shift; }

# Read with a while-loop, not `mapfile`: this runs on the laptop, and macOS
# ships bash 3.2, which has neither mapfile nor readarray.
TARGETS=()
while IFS= read -r line; do
  case "$line" in ''|\#*) continue;; esac
  TARGETS+=("$line")
done < scenarios.txt
[ "${#TARGETS[@]}" -gt 0 ] || { echo "scenarios.txt is empty"; exit 1; }

kubectl create configmap navsafe-figure2-cfg -n "$NS" \
  --from-file=run_figure2_worker.sh --dry-run=client -o yaml | kubectl apply -f -

mkdir -p rendered
n=0
for T in "${TARGETS[@]}"; do
  # A Job name is a DNS label: lower case, dots are not allowed.
  NAME="navsafe-fig2-$(echo "$T" | tr 'A-Z.' 'a-z-')"
  f="rendered/$NAME.yaml"
  sed -e "s|__NAME__|$NAME|g" -e "s|__TARGET__|$T|g" \
      -e "s|__OUTROOT__|$OUTROOT|g" \
      -e "s|__REPLAY__|$REPLAY|g" -e "s|__EVALF__|$EVALF|g" \
      templates/figure2.yaml > "$f"
  kubectl delete job "$NAME" -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl apply -f "$f" >/dev/null
  n=$((n+1))
  echo "  submitted $NAME  ->  $OUTROOT/$T"
done
echo "--- $n jobs submitted (${REPLAY} replay + ${EVALF} eval frames, DrivoR) ---"
kubectl get jobs -n "$NS" -l app=navsafe-figure2
