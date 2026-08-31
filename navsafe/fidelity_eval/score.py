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
import argparse, hashlib, json, os, shutil, subprocess, sys
from pathlib import Path

import yaml

RQE = Path("/avl-west/render_quality_eval")
UE = Path("/avl-west/drivearena_bench/unified_evaluator")
# UE/dataset/render is a symlink to this; the farms must be built at the real
# path, not under RQE, or FID and FDpi^k both read an empty directory.
RENDER = Path("/avl-west/drivearena_bench/render/navsim")
SPLITS = UE / "navsim/planning/script/config/common/train_test_split"

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
    # The eval pipeline's own render path, in its two configurations. Measured
    # 2026-08-31: the gRPC path matches `nre render` for sharpness (Laplacian
    # variance 32.0 vs 33.4) and the DiffusionHarmonizer post-pass is what
    # costs the eval its detail (10.9). These two rows are that ablation.
    "grpc_off":   ("/avl-west/fidelity_eval/grpc/hoff", (1920, 1080)),
    "grpc_on":    ("/avl-west/fidelity_eval/grpc/hon",  (1920, 1080)),
}
# Where the offline render lives; used only to translate the gRPC path's
# contiguous frame index back into the timestamp the manifest keys on.
OFFLINE_ROOT = RQE / "render_raw/nurec_native"


def _grpc_index_to_ts(sid):
    """{shard: [ts0, ts1, ...]} in render order, read off the offline render.

    render-grpc writes 000000.jpeg, 000001.jpeg ... with no timestamp anywhere,
    while the manifest keys on timestamp. Both walk the SAME training
    trajectory in the same order and emit the same count, so the offline
    render's time-sorted filenames ARE the index->timestamp table. Verified
    rather than assumed: grpc frame i best-matches offline frame i at 36-37 dB
    aligned, against 27-32 dB for i+-1.
    """
    table = {}
    for d in sorted(OFFLINE_ROOT.glob(f"{sid}*")):
        cam = d / "camera_pcam_f0"
        if not cam.is_dir():
            continue
        ts = sorted(int(p.stem) for p in cam.glob("*.jpg") if p.stem.isdigit())
        if ts:
            table[d.name] = ts
    return table


def resolve(side, man):
    """manifest frame -> the file that side actually wrote, keyed by data_path.

    The two sides do not agree on a layout and cannot be made to. DriveArena is
    driven by a token map and writes the manifest's own <log>/CAM_F0/<token>.jpg.
    NuRec renders per RECONSTRUCTION, and a scenario's reconstruction is four
    5s shards (<sid>s1..s4) whose frames are named by timestamp, so its path
    carries no log and no image token. Timestamp is the only key both sides
    share -- `nre render --frame-naming frame-end-timestamp` emits exactly the
    manifest ts, which is why the manifest pins ts per frame.
    """
    spec = SIDES[side][0]
    root = Path(spec) if str(spec).startswith("/") else RQE / spec
    out = {}
    if side.startswith("grpc_"):
        # Scoped PER SCENARIO on purpose. 47 timestamps in this manifest are
        # claimed by more than one scenario (overlapping windows), so a global
        # ts -> frame table would hand one scenario another's reconstruction.
        # Building the table inside the loop keeps every lookup inside the
        # scenario that owns the frame.
        for sc in man:
            table = _grpc_index_to_ts(sc["sid"])
            if not table:
                continue
            # ts -> (shard, index) for every shard of this scenario
            where = {}
            for shard, tss in table.items():
                for i, t in enumerate(tss):
                    where.setdefault(t, (shard, i))
            for f in sc["frames"]:
                hit = where.get(f["ts"])
                if not hit:
                    continue
                shard, i = hit
                for ext in ("jpeg", "jpg"):
                    p = root / shard / f"{i:06d}.{ext}"
                    if p.exists():
                        out[f["data_path"]] = p
                        break
        return out
    if side == "drivearena":
        for sc in man:
            for f in sc["frames"]:
                p = root / f["data_path"]
                if p.exists():
                    out[f["data_path"]] = p
        return out
    for sc in man:
        shards = sorted(root.glob(f"{sc['sid']}*"))
        for f in sc["frames"]:
            for d in shards:
                p = d / "camera_pcam_f0" / f"{f['ts']}.jpg"
                if p.exists():
                    out[f["data_path"]] = p
                    break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sides", nargs="*", default=["nurec", "drivearena"])
    ap.add_argument("--fid-only", action="store_true")
    a = ap.parse_args()

    man = json.load(open(RQE / "manifest.json"))["scenarios"]
    n_man = sum(len(s["frames"]) for s in man)
    found, present = {}, {}
    for k in a.sides:
        found[k] = resolve(k, man)
        present[k] = set(found[k])
        print(f"{k:<12} {len(present[k]):>6} / {n_man} manifest frames")
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
            os.symlink(found[k][rel], dst)
        n = sum(len(fs) for _, _, fs in os.walk(out))
        assert n == len(common), f"{out.name}: {n} links but common set is {len(common)}"
        print(f"  {out.name:<34} {n}")

    # trim the manifest to the common set so FVD walks exactly these frames
    for s in man:
        s["frames"] = [f for f in s["frames"] if f["data_path"] in common]
        s["n_frames"] = len(s["frames"])
        s["n_navtest"] = sum(f["is_navtest"] for f in s["frames"])
    cm = RQE / "manifest_common.json"
    # key is "scenes": compute_fvd_navsim.py's load_manifest reads that, not the
    # "scenarios" the pinned manifest uses
    json.dump({"scenes": man}, open(cm, "w"))
    wins = 0
    for s in man:
        idx = [f["i"] for f in s["frames"]]
        if not idx:
            continue
        runs, run = [], [idx[0]]
        for x, y in zip(idx, idx[1:]):
            if y == x + 1:
                run.append(y)
            else:                     # rebind, never clear: runs holds this list
                runs.append(run); run = [y]
        runs.append(run)
        wins += sum(max(0, (len(r) - 16) // 8 + 1) for r in runs)
    print(f"\ncommon set: {len(common)} frames, "
          f"{sum(s['n_navtest'] for s in man)} navtest tokens, ~{wins} FVD windows")

    # The matched-GT cache is keyed only by <tag>_<WxH>, and build_gt_cache skips
    # files that are already there while FID scores the WHOLE cache dir. So a
    # re-run on a smaller frame set silently scores today's renders against
    # yesterday's, larger, ground-truth set. Stamp the dir with the token set it
    # was built for and rebuild from scratch when that changes.
    stamp = hashlib.sha256("\n".join(sorted(common)).encode()).hexdigest()[:16]
    # FDpi^k runs a driving policy, so it can only be evaluated at frames that
    # are navsim scene anchors -- navtest tokens, which carry the 4 history
    # frames, 10 future frames and route a policy needs. The farm keeps every
    # common frame (the anchors' history is read from it); this yaml is what
    # restricts the evaluation points. One per side, named after the variation
    # so eval_navsim_unified_variation.sh picks it up by default.
    base = yaml.safe_load(open(SPLITS / "scene_filter/navtest.yaml"))
    for k in a.sides:
        toks = sorted({f["scene_token"] for sc in man for f in sc["frames"]
                       if f["is_navtest"] and f["data_path"] in common})
        sf = dict(base, tokens=toks)
        yaml.safe_dump({"data_split": "test",
                        "world_model_input_path": str(RENDER / f"{k}_cmp_navtest_frame"),
                        "scene_filter": sf},
                       open(SPLITS / f"{k}_cmp.yaml", "w"), sort_keys=False)
        print(f"  {k}_cmp.yaml: {len(toks)} navtest token(s) for FDpi^k")

    env = dict(os.environ, PYTHONPATH="")
    for k in a.sides:
        w, h = SIDES[k][1]
        cache = UE / "dataset/render_fid_cache/gt_navtest_matched" / f"{k}_cmp_{w}x{h}"
        marker = cache / ".token_set"
        if cache.exists() and (not marker.exists() or marker.read_text().strip() != stamp):
            print(f"  gt cache {cache.name}: built for a different frame set, rebuilding")
            shutil.rmtree(cache)
        subprocess.run([sys.executable, "scripts/compute_image_fid_navsim.py",
                        "--gen-dir", f"dataset/render/{k}_cmp_navtest_frame",
                        "--target-wh", str(w), str(h), "--tag", f"{k}_cmp",
                        "--navsim-test-root", str(UE / "dataset/navsim/sensor_blobs/test"),
                        "--gt-cache-root", "dataset/render_fid_cache/gt_navtest_matched"],
                       cwd=UE, env=env, check=True)
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(stamp)
    if not a.fid_only:
        subprocess.run([sys.executable, "scripts/compute_fvd_navsim.py",
                        "--variations", ",".join(f"{k}_cmp_navtest_frame" for k in a.sides),
                        "--manifest", str(cm),
                        "--out", str(RENDER / "fvd_cmp.json")], cwd=UE, env=env, check=True)


if __name__ == "__main__":
    main()
