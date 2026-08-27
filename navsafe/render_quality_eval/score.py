#!/usr/bin/env python3
"""Reduce both render sets to the frames they BOTH produced, then FID + FVD.

The reduction is the whole point of the experiment: FID scans a render dir
recursively and FVD walks the manifest, so if one side covers 15 000 frames and
the other 14 800, the two numbers are computed on different data and the
comparison is quietly void. This builds symlink farms restricted to the
intersection and ASSERTS every farm has the same count -- an unequal count is a
hard error, not a warning.

Rows are at each renderer's own native resolution. FID resizes the ground truth to
match the render, so the 1920x1080 row is scored against the untouched original and
the 400x224 rows against a bicubic downsample of it -- different references, which is
the situation unified_evaluator's own published table is in too (DreamStream 11.78
@1920x1080 next to DriveArena 41.80 @400x224). Adding a matched-resolution control
row later is one extra render stage, if it is ever asked for.
"""
import argparse, json, os, subprocess, sys
from pathlib import Path

RQE = Path("/avl-west/render_quality_eval")
UE = Path("/avl-west/drivearena_bench/unified_evaluator")
RENDER = RQE / "render"                       # what UE sees as dataset/render

# Each renderer is scored at ITS OWN native output resolution -- the same thing
# unified_evaluator's reference table does. Resolution is part of what a renderer
# delivers, not a nuisance variable to equalise away: NavSafe hands a policy
# 1920x1080, DriveArena can only hand it 400x224.
#
#   nurec       what NavSafe actually feeds a policy
#   drivearena  what DriveArena actually feeds a policy -- 400x224 is its only output
SIDES = {
    "nurec":      ("render_raw/nurec_native", (1920, 1080)),
    "drivearena": ("render_raw/drivearena",   (400, 224)),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sides", nargs="*", default=["nurec", "drivearena"])
    ap.add_argument("--fid-only", action="store_true")
    a = ap.parse_args()

    man = json.load(open(RQE / "manifest.json"))["scenarios"]
    present = {}
    for k in a.sides:
        src = RQE / SIDES[k][0]
        present[k] = {f["data_path"] for s in man for f in s["frames"]
                      if (src / f["data_path"]).exists()}
        print(f"{k:<12} {len(present[k]):>6} frames")
    common = set.intersection(*present.values())
    print(f"{'common':<12} {len(common):>6} frames")
    if not common:
        sys.exit("no common frames")

    # symlink farms, pruned of anything outside the current intersection
    for k in a.sides:
        out = RENDER / f"{k}_cmp_navtest_frame"
        for root, _, files in os.walk(out):
            for f in files:
                p = Path(root) / f
                if str(p.relative_to(out)) not in common:
                    p.unlink()
        for rel in sorted(common):
            dst = out / rel
            if dst.exists() or dst.is_symlink():
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(RQE / SIDES[k][0] / rel, dst)
        n = sum(len(fs) for _, _, fs in os.walk(out))
        assert n == len(common), f"{out.name}: {n} links but common set is {len(common)}"
        print(f"  {out.name:<34} {n}")

    # trim the manifest to the common set so FVD walks exactly these frames
    for s in man:
        s["frames"] = [f for f in s["frames"] if f["data_path"] in common]
        s["n_frames"] = len(s["frames"])
        s["n_navtest"] = sum(f["is_navtest"] for f in s["frames"])
    cm = RQE / "manifest_common.json"
    json.dump({"scenarios": man}, open(cm, "w"))
    wins = 0
    for s in man:
        idx = [f["i"] for f in s["frames"]]
        if not idx:
            continue
        runs, run = [], [idx[0]]
        for x, y in zip(idx, idx[1:]):
            (run.append(y) if y == x + 1 else (runs.append(run), run.clear(), run.append(y)))
        runs.append(run)
        wins += sum(max(0, (len(r) - 16) // 8 + 1) for r in runs)
    print(f"\ncommon set: {len(common)} frames, "
          f"{sum(s['n_navtest'] for s in man)} navtest tokens, ~{wins} FVD windows")

    env = dict(os.environ, PYTHONPATH="")
    for k in a.sides:
        w, h = SIDES[k][1]
        subprocess.run([sys.executable, "scripts/compute_image_fid_navsim.py",
                        "--gen-dir", f"dataset/render/{k}_cmp_navtest_frame",
                        "--target-wh", str(w), str(h), "--tag", f"{k}_cmp",
                        "--navsim-test-root", str(UE / "dataset/navsim/sensor_blobs/test"),
                        "--gt-cache-root", "dataset/render_fid_cache/gt_navtest_matched"],
                       cwd=UE, env=env)
    if not a.fid_only:
        subprocess.run([sys.executable, "scripts/compute_fvd_navsim.py",
                        "--variations", ",".join(f"{k}_cmp_navtest_frame" for k in a.sides),
                        "--manifest", str(cm),
                        "--out", str(RENDER / "fvd_cmp.json")], cwd=UE, env=env)


if __name__ == "__main__":
    main()
