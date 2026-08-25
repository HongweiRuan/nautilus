#!/usr/bin/env python3
"""Aggregate the sweep's per-scenario scores into one table per model and seed.

Reads every outputs/<row>/seed<N>/<token>/navsafe_metrics.json and reports the
mean of each NavSafe metric plus, explicitly, how many scenarios are MISSING.
A benchmark mean over an unstated denominator is the failure this exists to
prevent: 118 of 127 scenarios averaged silently reads as a score, not as a
partially finished sweep.

    kubectl cp collect.py cogrob/horuan-nexussim:/tmp/collect.py
    kubectl exec -n cogrob horuan-nexussim -- python3 /tmp/collect.py
    kubectl exec -n cogrob horuan-nexussim -- python3 /tmp/collect.py --csv > table.csv
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path("/avl-west/navsafe_eval")


def flatten(blob: dict) -> dict[str, float]:
    """navsafe_metrics.json has had two layouts; take the scalars from either."""
    out: dict[str, float] = {}
    for key in ("metrics", "scores", "summary"):
        if isinstance(blob.get(key), dict):
            blob = {**blob, **blob[key]}
    for k, v in blob.items():
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[k] = float(v)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", action="store_true")
    ap.add_argument("--outputs", default=str(ROOT / "outputs"))
    args = ap.parse_args()

    total = len(list((ROOT / "dataset").iterdir()))
    rows = []
    for model_dir in sorted(Path(args.outputs).iterdir()):
        if not model_dir.is_dir():
            continue
        for seed_dir in sorted(model_dir.glob("seed*")):
            cells = sorted(seed_dir.glob("*/navsafe_metrics.json"))
            if not cells:
                continue
            acc: dict[str, list[float]] = {}
            for cell in cells:
                try:
                    flat = flatten(json.loads(cell.read_text()))
                except Exception:                      # noqa: BLE001 - one bad file is not the table
                    continue
                for k, v in flat.items():
                    acc.setdefault(k, []).append(v)
            rows.append((model_dir.name, seed_dir.name, len(cells), total - len(cells),
                         {k: sum(v) / len(v) for k, v in acc.items()}))

    if not rows:
        print("no scored cells yet")
        return 0

    keys = [k for k in ("driving_score", "success_rate", "efficiency", "comfort",
                        "route_completion")
            if any(k in r[4] for r in rows)]
    keys += sorted({k for r in rows for k in r[4]} - set(keys))[:4]

    if args.csv:
        print(",".join(["model", "seed", "scored", "missing", *keys]))
        for m, s, n, miss, vals in rows:
            print(",".join([m, s, str(n), str(miss)]
                           + [f"{vals.get(k, float('nan')):.4f}" for k in keys]))
        return 0

    head = f"{'model':20s} {'seed':6s} {'scored':>7s} {'missing':>8s} " + \
           " ".join(f"{k[:14]:>14s}" for k in keys)
    print(head)
    print("-" * len(head))
    for m, s, n, miss, vals in rows:
        line = f"{m:20s} {s:6s} {n:7d} {miss:8d} " + \
               " ".join(f"{vals.get(k, float('nan')):>14.4f}" for k in keys)
        print(line)
    print("-" * len(head))
    print(f"denominator: {total} scenarios")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
