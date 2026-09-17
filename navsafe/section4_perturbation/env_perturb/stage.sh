#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
POD=${1:?Usage: stage.sh POD [CONTAINER]}; CONTAINER=${2:-eval}
DEST=/avl-west/navsafe_eval/section4_env_perturb/20260912-v1
kubectl exec -n cogrob "$POD" -c "$CONTAINER" -- bash -lc "test ! -e '$DEST'"
ARCHIVE=$(mktemp /tmp/env-perturb-stage.XXXXXX.tar.gz)
tar -czf "$ARCHIVE" -C "$HERE" .
kubectl cp -n cogrob -c "$CONTAINER" "$ARCHIVE" "$POD":/tmp/env-perturb-stage.tar.gz
kubectl exec -n cogrob "$POD" -c "$CONTAINER" -- bash -lc "mkdir -p '$DEST' && tar -xzf /tmp/env-perturb-stage.tar.gz -C '$DEST' && python3 '$DEST/snapshot_runtime.py' --repo /hugsim-storage/NexusSim --output '$DEST/runtime.tar.gz'"
echo "staged: $DEST"
