#!/usr/bin/env python
"""Is every model in models.tsv actually runnable before we spend 60 GPUs on it?

Answers one question per row: would `eval_py123d.py --model-type M --checkpoint C`
get as far as the first inference call. Three ways it would not, all checked here:

  * the adapter never registered  — the module raised on import (a missing extra,
    a version clash) and the registry swallowed it, so --model-type M comes back
    "unknown" 15 minutes into a pod's life rather than at submit time;
  * the checkpoint is not there;
  * the checkpoint is there but its COMPANIONS are not. DiffusionDrive's kmeans
    anchor and SparseDriveV2's vocabularies are resolved from
    Path(checkpoint).resolve().parent, so a checkpoint moved or symlinked out of
    its zoo directory loads and then fails at the first forward pass.

Weights are never loaded: this has to be cheap enough to run before every sweep.

Run it through the dev pod, which has the eval venv:
    kubectl exec -n cogrob horuan-nexussim -- /root/nexussim-venv/bin/python \
        /tmp/check_adapters.py /tmp/models.tsv
(check_adapters.sh does the copying.)
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ZOO = Path(os.environ.get("NAVSAFE_ZOO", "/avl-west/navsafe_eval/model_zoo"))

#: Files an adapter resolves from the checkpoint's own directory. Named per
#: model_type because that is what decides the resolution, not the row.
COMPANIONS = {
    "diffusiondrive": ["kmeans_navsim_traj_20.npy"],
    "sparsedrivev2": [
        "kmeans_det_900.npy", "kmeans_map_100.npy", "kmeans_motion_6.npy",
        "path_1024.npy", "trajectory_1024_256.npz", "vel_seq_K256_t30.npy",
        "velocity_256.npy",
    ],
}

#: Adapters that fork a server process under a SEPARATE venv (NAVSAFE_VLA_PYTHON).
#: None of them are in models.tsv today; the check stays so that adding one back
#: reports the missing venv here instead of in 30 pods at once.
SUBPROCESS_VLA = {"recogdrive", "mtdrive", "autovla", "drivelaw", "simwam"}


def rows(tsv: Path):
    for line in tsv.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 3:
            print(f"!! malformed row: {line}", file=sys.stderr)
            continue
        yield parts[0], parts[1], parts[2]


def main() -> int:
    tsv = Path(sys.argv[1] if len(sys.argv) > 1 else "models.tsv")
    from nexussim.engine.registry import get_registry

    registry = get_registry()
    registry.discover_entry_points()

    bad = 0
    print(f"zoo = {ZOO}")
    print(f"{'row':20s} {'model_type':16s} {'registry':10s} {'ckpt':10s} {'companions':12s}")
    print("-" * 76)
    for row, mt, ck in rows(tsv):
        problems = []

        try:
            registry.lookup("policies", mt)
            reg = "ok"
        except Exception as exc:                       # noqa: BLE001 - report, never raise
            reg = "UNKNOWN"
            problems.append(f"adapter {mt!r} did not register ({type(exc).__name__}: {exc})")

        if ck == "none":
            ckst, comp = "n/a", "n/a"
        else:
            path = (ZOO / ck)
            if path.exists():
                ckst = "ok"
                missing = [c for c in COMPANIONS.get(mt, [])
                           if not (path.resolve().parent / c).exists()]
                if missing:
                    comp = "MISSING"
                    problems.append(f"companions absent beside the checkpoint: {', '.join(missing)}")
                else:
                    comp = "ok" if COMPANIONS.get(mt) else "-"
                if path.is_symlink():
                    problems.append(
                        f"{ck} is a SYMLINK; companions resolve from the link TARGET's "
                        "directory, so keep the zoo directory intact instead")
            else:
                ckst, comp = "MISSING", "-"
                problems.append(f"no checkpoint at {path}")

        if mt in SUBPROCESS_VLA:
            vla = os.environ.get("NAVSAFE_VLA_PYTHON")
            if not vla:
                import nexussim.policy.sensor.vla_client as vc
                vla = vc.DEFAULT_VLA_PYTHON
            if not os.path.exists(vla):
                problems.append(
                    f"subprocess-VLA adapter, but its venv is absent: {vla} "
                    "(set NAVSAFE_VLA_PYTHON)")

        print(f"{row:20s} {mt:16s} {reg:10s} {ckst:10s} {comp:12s}")
        for p in problems:
            bad += 1
            print(f"    !! {p}")

    print("-" * 76)
    print("ALL ROWS READY" if not bad else f"{bad} PROBLEM(S) — do not submit until fixed")
    return 0 if not bad else 1


if __name__ == "__main__":
    raise SystemExit(main())
