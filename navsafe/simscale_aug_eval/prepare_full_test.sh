#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kubectl apply -f "$HERE/prepare-full-test.yaml"
kubectl get job -n cogrob navsafe-full-test-prepare
echo "Monitor with: kubectl logs -n cogrob -f job/navsafe-full-test-prepare"
