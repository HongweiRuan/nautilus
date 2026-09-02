#!/bin/bash
# One shard per worker, two GPUs each (serve-grpc on GPU 0, the eval on GPU 1).
# NODES lists one entry per worker, so a node with four free GPUs appears twice.
set -eo pipefail
cd "$(dirname "$0")"
NODES=(ry-gpu-05 ry-gpu-06 ry-gpu-08 ry-gpu-08 ry-gpu-08 ry-gpu-12 ry-gpu-12)
N=${#NODES[@]}
kubectl create configmap navsafe-evalrender-cfg -n cogrob \
  --from-file=run_evalrender_worker.sh --dry-run=client -o yaml | kubectl apply -f -
mkdir -p rendered/evalrender
for i in "${!NODES[@]}"; do
  f=rendered/evalrender/w$(printf %02d "$i").yaml
  sed -e "s/__NAME__/navsafe-evalrender-w$(printf %02d "$i")/" \
      -e "s/__NODE__/${NODES[$i]}.sdsc.optiputer.net/" \
      -e "s/__IDX__/$i/" -e "s/__N__/$N/" templates/evalrender.yaml > "$f"
  kubectl apply -f "$f"
done
echo "--- $N workers over ${#NODES[@]} slots ---"
kubectl get jobs -n cogrob | grep evalrender
