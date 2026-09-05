#!/bin/bash
# WORKERS shards on the public pool. No node is named: the template asks only
# for a 24 GB GPU, so a shard lands wherever capacity turns up and a Pending
# one starts by itself when some frees.
set -eo pipefail
cd "$(dirname "$0")"
N=${1:-7}
# A Job's spec.template is IMMUTABLE, so a re-submit under the same name fails
# with "field is immutable" -- and a resume IS a re-submit here, because the
# worker's resume is per-cell `.done` rather than per-job. Same RUNID trick the
# other stages use.
RUNID=${RUNID:-$(date +%m%d%H%M)}
kubectl create configmap navsafe-evalrender-cfg -n cogrob \
  --from-file=run_evalrender_worker.sh --dry-run=client -o yaml | kubectl apply -f -
mkdir -p rendered/evalrender
for i in $(seq 0 $((N-1))); do
  f=rendered/evalrender/w$(printf %02d "$i")-$RUNID.yaml
  sed -e "s/__NAME__/navsafe-evalrender-w$(printf %02d "$i")-$RUNID/" \
      -e "s/__IDX__/$i/" -e "s/__N__/$N/" templates/evalrender.yaml > "$f"
  kubectl apply -f "$f"
done
echo "--- $N shards submitted (runid $RUNID) ---"
kubectl get jobs -n cogrob | grep evalrender
