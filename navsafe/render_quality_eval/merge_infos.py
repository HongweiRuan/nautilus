#!/usr/bin/env python3
"""Concatenate every shard's per-log pkls into one corpus-wide ann_file.

The converter writes one pkl per log under <out-dir>/tmp/ and only combines at
the very end of its own run, so with the stage sharded the combining has to
happen here, across all shards' tmp dirs. Both the train and val sides are
folded in: which side a log landed on is an artefact of the converter refusing
an empty train split, not something downstream cares about.

Image/lidar paths are canonicalised back to the shared nuplan root on the way
through. The converter bakes absolute paths, and it ran against the shard's
node-local root (/tmp/nproot), which does not exist on the pod that later reads
this file -- DriveArena loads the real camera frames as its reference view and
died on every one of them. The rewrite is exact rather than a guess: inside
that root, maps/ and sensor_blobs/ are symlinks to the shared copy (see
prep_infos_shard.py), so the two prefixes always named the same bytes.
"""
import glob, os, pickle

RQE = "/avl-west/render_quality_eval"
LOCAL_ROOT, SHARED_ROOT = "/tmp/nproot/", "/avl-west/nuplan/"
pats = [f"{RQE}/infos/work/tmp/*.pkl", f"{RQE}/infos/work/sh*/tmp/*.pkl"]
files = sorted({p for pat in pats for p in glob.glob(pat)})
def canonicalise(o):
    """Rewrite every baked-in node-local path in place, at any depth."""
    if isinstance(o, dict):
        for k, v in o.items():
            if isinstance(v, str) and v.startswith(LOCAL_ROOT):
                o[k] = SHARED_ROOT + v[len(LOCAL_ROOT):]
            else:
                canonicalise(v)
    elif isinstance(o, (list, tuple)):
        for v in o:
            canonicalise(v)


infos, meta, seen_logs = [], None, set()
for p in files:
    try:
        d = pickle.load(open(p, "rb"))
    except Exception as e:
        print(f"  !! unreadable {os.path.basename(p)}: {e}"); continue
    canonicalise(d["infos"])
    infos.extend(d["infos"]); meta = meta or d.get("metadata")
    seen_logs.add(os.path.basename(p).replace("_infos_train.pkl", "").replace("_infos_val.pkl", ""))
out = f"{RQE}/infos/nuplan_infos_all.pkl"
pickle.dump({"infos": infos, "scene_tokens": [], "metadata": meta or {"version": "nuplan"}},
            open(out, "wb"))
print(f"[merge] {len(files)} pkl(s), {len(seen_logs)} log(s), {len(infos)} frames -> {out}")

# a single unreadable reference frame kills the whole DriveArena dataloader, so
# check one here rather than 20 GPU-minutes from now
probe = infos[0]["cams"]["CAM_F0"]["data_path"]
assert probe.startswith(SHARED_ROOT), f"path not canonicalised: {probe}"
assert os.path.exists(probe), f"canonical path does not resolve: {probe}"
print(f"[merge] paths canonicalised, probe resolves: {probe}")
