#!/bin/bash
# Copy the worker script and the model/scenario lists onto the PVC, where the
# jobs read them from.
#
# This replaces the ConfigMap the fleet used to mount at /cfg. A ConfigMap meant
# every parameter change was a `kubectl create configmap ... | kubectl apply`
# followed by restarting pods to pick it up; a file on the PVC is just a file,
# and job_offset_eval.yaml names it by absolute path.
#
# Run this after editing anything under config/, and BEFORE submitting. Pods
# read these at startup, so a running worker keeps the version it started with.
set -uo pipefail
cd "$(dirname "$0")/.."
DEST=/avl-west/runs/20260905-handoff-perturb-demo/tooling

POD=$(kubectl get pods -n cogrob --no-headers 2>/dev/null \
      | grep -m1 -E '^navsafe-.*Running' | awk '{print $1}')
[ -z "$POD" ] && { echo "no running pod to copy through — start one, or use any pod that mounts /avl-west"; exit 1; }
echo "copying through $POD -> $DEST"

kubectl exec -n cogrob "$POD" -- mkdir -p "$DEST" || exit 1
for f in config/run_worker.sh config/models.tsv config/models_simwam.tsv \
         config/models_addon.tsv config/models_il.tsv config/selection.json \
         config/selection_plain.json config/selection_edit.json; do
  [ -f "$f" ] || { echo "  MISSING $f"; continue; }
  kubectl cp "$f" "cogrob/$POD:$DEST/$(basename $f)" || { echo "  FAILED $f"; exit 1; }
  printf "  %-24s %s\n" "$(basename $f)" "$(wc -c < "$f" | tr -d ' ') bytes"
done

echo "=== on the PVC now ==="
kubectl exec -n cogrob "$POD" -- ls -la "$DEST"
echo "=== local vs cluster checksums ==="
for f in config/*; do
  l=$(shasum "$f" | awk '{print $1}')
  r=$(kubectl exec -n cogrob "$POD" -- shasum "$DEST/$(basename $f)" 2>/dev/null | awk '{print $1}')
  [ "$l" = "$r" ] && s=ok || s="MISMATCH"
  printf "  %-24s %s\n" "$(basename $f)" "$s"
done
