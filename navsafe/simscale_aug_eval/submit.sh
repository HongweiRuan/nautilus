#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

kubectl apply -f "$HERE/prepare-assets.yaml"
kubectl wait -n cogrob --for=condition=complete job/navsafe-simscale-assets --timeout=45m
kubectl logs -n cogrob job/navsafe-simscale-assets --tail=80
kubectl apply -f "$HERE/jobs.yaml"
kubectl get jobs -n cogrob -l navsafe-batch=simscale-aug
