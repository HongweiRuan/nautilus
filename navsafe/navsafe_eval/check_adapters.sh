#!/usr/bin/env bash
# Run check_adapters.py inside the dev pod (the only place with the eval venv).
# Exits non-zero if any row in models.tsv is not runnable — submit_eval.sh calls
# this first and refuses to submit on a failure.
set -euo pipefail
cd "$(dirname "$0")"
NS=${NS:-cogrob}
POD=${POD:-horuan-nexussim}
kubectl cp check_adapters.py "$NS/$POD:/tmp/check_adapters.py"
kubectl cp models.tsv        "$NS/$POD:/tmp/models.tsv"
kubectl exec -n "$NS" "$POD" -- /root/nexussim-venv/bin/python /tmp/check_adapters.py /tmp/models.tsv
