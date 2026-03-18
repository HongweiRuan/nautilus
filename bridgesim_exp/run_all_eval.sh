#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================="
echo "  Launching all 18 evaluation jobs"
echo "=========================================="

# --- eval_navhard_60 (6 jobs) ---
echo ""
echo ">>> eval_navhard_60"
pushd "${SCRIPT_DIR}/eval_navhard_60" > /dev/null
for method in dd ddv2 rap drivor ltf transfuser; do
    echo "  Starting: navhard_60 - ${method}"
    bash "bash_navhard_eval_${method}_60.sh"
done
popd > /dev/null

# --- eval_advbmt_navhard_baseline_60 (6 jobs) ---
echo ""
echo ">>> eval_advbmt_navhard_baseline_60"
pushd "${SCRIPT_DIR}/eval_advbmt_navhard_baseline_60" > /dev/null
for method in dd ddv2 rap drivor ltf transfuser; do
    echo "  Starting: advbmt_navhard_baseline_60 - ${method}"
    bash "bash_advbmt_navhard_eval_${method}.sh"
done
popd > /dev/null

# --- eval_navhard_idm_baseline (6 jobs) ---
echo ""
echo ">>> eval_navhard_idm_baseline"
pushd "${SCRIPT_DIR}/eval_navhard_idm_baseline" > /dev/null
for method in dd ddv2 rap drivor ltf transfuser; do
    echo "  Starting: navhard_idm_baseline - ${method}"
    bash "bash_navhard_eval_${method}_idm_baseline.sh"
done
popd > /dev/null

echo ""
echo "=========================================="
echo "  All 18 evaluation jobs launched!"
echo "=========================================="
