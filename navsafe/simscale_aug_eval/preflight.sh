#!/usr/bin/env bash
set -euo pipefail

kubectl exec -n cogrob horuan-nexussim -c nexussim-container -- bash -lc '
python - <<"PY"
from pathlib import Path

root = Path("/avl-west/navsafe_eval")
data = root / "full_test"
expected = {p.stem for p in (root / "metrics_all/drivor/seed0").glob("*.json")}
actual = {p.name for p in data.iterdir()} if data.is_dir() else set()
bad = []
for token in sorted(expected):
    path = data / token
    if not (
        path.is_dir()
        and (path / "manifest.json").is_file()
        and (path / "arrow").is_dir()
        and len(list(path.glob("*.usdz"))) == 4
    ):
        bad.append(token)
extra = sorted(actual - expected)
if len(expected) != 280 or bad or extra:
    raise SystemExit(
        f"PRECHECK FAILED expected={len(expected)} incomplete={len(bad)} "
        f"extra={len(extra)}; run ./prepare_full_test.sh first"
    )
nuplan = root / "aug_zoo/SimScale/nuplan-devkit"
if not (nuplan / "nuplan/common/actor_state/ego_state.py").is_file():
    raise SystemExit(f"PRECHECK FAILED: nuplan source missing at {nuplan}")
print("PRECHECK OK: exact 280 bundles and pinned dependency assets present")
PY
'
