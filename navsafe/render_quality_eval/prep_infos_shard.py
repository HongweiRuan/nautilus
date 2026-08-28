#!/usr/bin/env python3
"""prep_infos_shard.py <shard_logs.txt> — set one infos shard up to run locally.

Builds a nuplan root containing ONLY this shard's logs, entirely on the pod's
local disk. That isolation is not cosmetic:

  * `NuPlanDBWrapper` opens every .db in the splits dir it is given, so a shared
    dir would make each shard try to open the other shards' dbs;
  * those dbs are staged to LOCAL disk because the nuPlan ORM issues millions of
    small page reads and is pathological on CephFS -- and local disk is per-node,
    so a shared symlink farm would dangle for every shard but the one that
    populated it.

maps and sensor_blobs stay as symlinks to the shared copy: they are read in
bulk, not by the ORM.
"""
import json, os, shutil, sys

RQE = "/avl-west/render_quality_eval"
NUPLAN = "/avl-west/nuplan"
ROOT = "/tmp/nproot"          # local, per-pod
DBDIR = "/tmp/nplocal"

logs = [l.strip() for l in open(sys.argv[1]) if l.strip()]

# windows.json is shared and identical for every shard; write it if absent
os.makedirs(f"{RQE}/infos", exist_ok=True)
wpath = f"{RQE}/infos/windows.json"
if not os.path.exists(wpath):
    man = json.load(open(f"{RQE}/manifest.json"))["scenarios"]
    json.dump([[s["frames"][0]["ts"] - 250_000, s["frames"][-1]["ts"] + 250_000] for s in man],
              open(wpath, "w"))

os.makedirs(f"{ROOT}/nuplan-v1.1/splits/trainval", exist_ok=True)
os.makedirs(DBDIR, exist_ok=True)
for src, dst in ((f"{NUPLAN}/maps", f"{ROOT}/maps"),
                 (f"{NUPLAN}/nuplan-v1.1/sensor_blobs", f"{ROOT}/nuplan-v1.1/sensor_blobs")):
    if not os.path.islink(dst):
        os.symlink(src, dst)

staged = 0
for l in logs:
    src = f"{NUPLAN}/nuplan-v1.1/splits/test/{l}.db"
    loc = f"{DBDIR}/{l}.db"
    link = f"{ROOT}/nuplan-v1.1/splits/trainval/{l}.db"
    if not os.path.exists(src):
        print(f"  !! missing db {src}"); continue
    if not os.path.exists(loc):
        shutil.copyfile(src, loc); staged += 1
    if os.path.islink(link) or os.path.exists(link):
        os.remove(link)
    os.symlink(loc, link)

# the converter reads dreamer_train / dreamer_val and KeyErrors if train yields
# no pkl, so the shortest log goes there; merge_infos.py folds both sides back in
def span(l):
    a, b = l.rsplit("_", 2)[-2:]
    return int(b) - int(a)
train = [min(logs, key=span)] if logs else []
val = [l for l in logs if l not in train]
with open("/tmp/split.yaml", "w") as f:
    f.write("_target_: nuplan.planning.training.data_loader.log_splitter.LogSplitter\n")
    f.write("_convert_: 'all'\n\nlog_splits:\n")
    for k, v in (("dreamer_train", train), ("dreamer_val", val)):
        f.write(f"  {k}:\n")
        for l in v:
            f.write(f"    - {l}\n")
print(f"[prep] {len(logs)} log(s), staged {staged} db(s) -> {ROOT}")
