#!/usr/bin/env bash
# Drive aux -> link -> train for a batch of already-NCore-converted navhard scenes,
# using the MATERIALIZED per-scene yamls (aux/<scene>/aux.yaml, train/<scene>/...).
# Submits all aux jobs in parallel, then per scene waits for aux, links aux stores,
# and submits the chosen train variant. Requires the horuan-nexussim pod up (for the
# link step) and NGC secrets in cogrob.
#
# Usage:  ./batch_recon.sh <scene_token> [<scene_token> ...]
#         TRAIN=fullres ./batch_recon.sh <scene>   # train variant: static|fullres|5cam (default static)
set -euo pipefail
NS=cogrob
POD=horuan-nexussim
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$DIR")"          # nurec_navhard/
TRAIN="${TRAIN:-static}"           # which train/<scene>/train-<TRAIN>.yaml to submit
SCENES=("$@")
[ ${#SCENES[@]} -gt 0 ] || { echo "usage: [TRAIN=static|fullres|5cam] $0 <scene_token> [...]"; exit 1; }

for S in "${SCENES[@]}"; do
  [ -f "$ROOT/aux/$S/aux.yaml" ] || { echo "!! no per-scene yamls for '$S' (expected $ROOT/aux/$S/aux.yaml)"; exit 1; }
done

echo "=== submitting aux for ${#SCENES[@]} scenes ==="
for S in "${SCENES[@]}"; do
  kubectl apply -f "$ROOT/aux/$S/aux.yaml"
done

for S in "${SCENES[@]}"; do
  echo "=== [$S] waiting for aux ==="
  until kubectl get job "navhard-aux-$S" -n $NS -o jsonpath='{.status.conditions[0].type}' 2>/dev/null \
        | grep -qE "Complete|Failed"; do sleep 20; done
  ST=$(kubectl get job "navhard-aux-$S" -n $NS -o jsonpath='{.status.conditions[0].type}')
  if [ "$ST" != "Complete" ]; then echo "!! [$S] aux $ST — skipping"; continue; fi

  echo "=== [$S] linking aux -> manifest base ==="
  kubectl exec $POD -n $NS -- /root/nexussim-venv/bin/python -c "
import sys; sys.path.insert(0,'/hugsim-storage/NexusSim')
from pathlib import Path
from nexussim.gs3d_converter.nurec_runner import _link_aux_to_manifest_base as L, _ncore_manifest as M
cd=Path('/avl-west/r2s_work/$S/clips/$S'); L(cd, M(cd)); print('linked $S')"

  echo "=== [$S] submitting train ($TRAIN) ==="
  T="$ROOT/train/$S/train-$TRAIN.yaml"
  [ -f "$T" ] || { echo "!! [$S] no $T — skipping train"; continue; }
  kubectl apply -f "$T"
done
echo "=== all trains submitted ==="
kubectl get jobs -n $NS | grep navhard-train || true
