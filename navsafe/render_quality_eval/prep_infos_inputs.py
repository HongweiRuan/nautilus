#!/usr/bin/env python3
"""Everything the nuPlan converter needs, derived from the pinned manifest.

  infos/split.yaml   the logs to convert, in the dreamer_train/dreamer_val keys
                     create_nuplan_infos(version="dreamer-trainval") reads. The
                     train side cannot be empty (load_and_combine_pkl_files
                     KeyErrors on a missing 'train'), so the shortest log goes
                     there and merge_infos.py folds it back in.
  infos/windows.json [t0,t1] per scenario for NUPLAN_BENCH_WINDOWS, the patch
                     that stops the converter walking whole logs.
  nuplan_root/       symlink farm: maps + sensor_blobs point at the shared
                     dataset, but the log dbs are COPIED to the pod's local disk
                     because the nuPlan ORM is pathological on CephFS.
"""
import json, os, shutil

RQE = "/avl-west/render_quality_eval"
NUPLAN = "/avl-west/nuplan"
LOCAL = "/nuplan_local_db"

man = json.load(open(f"{RQE}/manifest.json"))["scenarios"]
os.makedirs(f"{RQE}/infos", exist_ok=True)

wins = [[s["frames"][0]["ts"] - 250_000, s["frames"][-1]["ts"] + 250_000] for s in man]
json.dump(wins, open(f"{RQE}/infos/windows.json", "w"))

logs = sorted({s["log"] for s in man})
def span(l):
    a, b = l.rsplit("_", 2)[-2:]
    return int(b) - int(a)
train = [min(logs, key=span)]
val = [l for l in logs if l not in train]
with open(f"{RQE}/infos/split.yaml", "w") as f:
    f.write("_target_: nuplan.planning.training.data_loader.log_splitter.LogSplitter\n")
    f.write("_convert_: 'all'\n\nlog_splits:\n")
    for k, v in (("dreamer_train", train), ("dreamer_val", val)):
        f.write(f"  {k}:\n")
        for l in v:
            f.write(f"    - {l}\n")

root = f"{RQE}/nuplan_root"
os.makedirs(f"{root}/nuplan-v1.1/splits/trainval", exist_ok=True)
os.makedirs(LOCAL, exist_ok=True)
for src, dst in ((f"{NUPLAN}/maps", f"{root}/maps"),
                 (f"{NUPLAN}/nuplan-v1.1/sensor_blobs", f"{root}/nuplan-v1.1/sensor_blobs")):
    if not os.path.islink(dst):
        os.symlink(src, dst)
staged = 0
for l in logs:
    src = f"{NUPLAN}/nuplan-v1.1/splits/test/{l}.db"
    loc, link = f"{LOCAL}/{l}.db", f"{root}/nuplan-v1.1/splits/trainval/{l}.db"
    if not os.path.exists(src):
        print(f"  !! missing db {src}"); continue
    if not os.path.exists(loc):
        shutil.copyfile(src, loc); staged += 1
    if os.path.islink(link) or os.path.exists(link):
        os.remove(link)
    os.symlink(loc, link)
print(f"[prep] {len(man)} scenarios, {len(logs)} logs, {len(wins)} windows, staged {staged} db(s)")
