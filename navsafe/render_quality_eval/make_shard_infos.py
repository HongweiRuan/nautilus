#!/usr/bin/env python3
"""make_shard_infos.py <shard.txt> <out_infos.pkl> <out_tokens.json>

Cut the corpus-wide nuPlan infos down to one shard's scenarios, and emit the
lidar_pc-token -> "<log>/CAM_F0/<image_token>.jpg" map that the patched
tools/test.py needs to name its output.

Why per-shard rather than one global file: `scene_tokens` is what
`build_clips_2hz` groups by, and the first token of each group is where the
autoregressive reference resets. Feeding a shard the full corpus grouping would
make it generate everything; feeding it a grouping of only its own scenarios
keeps each job's work disjoint and its reference chain correct.

Frames are restricted to the manifest's 2 Hz set, so DriveArena generates
exactly the frames that get scored -- not the converter's full 10 Hz stream.
"""
import json, os, pickle, sys

RQE = "/avl-west/render_quality_eval"
INFOS = f"{RQE}/infos/nuplan_infos_all.pkl"
MANIFEST = f"{RQE}/manifest.json"
CAPTIONS = f"{RQE}/captions.json"

shard_p, out_infos, out_tokens = sys.argv[1:4]
want_sids = {l.strip() for l in open(shard_p) if l.strip()}

man = {s["sid"]: s for s in json.load(open(MANIFEST))["scenarios"]}
caps = json.load(open(CAPTIONS))["captions"] if os.path.exists(CAPTIONS) else {}
data = pickle.load(open(INFOS, "rb"))
infos = data["infos"]


def log_of(i):
    return i["lidar_path"].split("sensor_blobs/")[-1].split("/")[0]


def camf0(i):
    return os.path.basename(i["cams"]["CAM_F0"]["data_path"]).split(".")[0]


by_log = {}
for i in infos:
    by_log.setdefault(log_of(i), []).append(i)
for v in by_log.values():
    v.sort(key=lambda e: e["timestamp"])

out, groups, report = [], [], []
for sid in sorted(want_sids):
    sc = man.get(sid)
    if sc is None:
        report.append((sid, 0, 0)); continue
    want_tokens = {f["image_token"] for f in sc["frames"]}
    win = [i for i in by_log.get(sc["log"], [])
           if sc["t0"] <= i["timestamp"] <= sc["t1"] and camf0(i) in want_tokens]
    win.sort(key=lambda e: e["timestamp"])
    if not win:
        report.append((sid, 0, len(sc["frames"]))); continue
    cap = caps.get(sid) or caps.get(sc["map_location"]) or ""
    for i in win:
        i["description"] = cap
        i["is_first_frame"] = False
    out.extend(win)
    groups.append([i["token"] for i in win])
    report.append((sid, len(win), len(sc["frames"])))

pickle.dump({"infos": out, "scene_tokens": groups,
             "metadata": data.get("metadata", {"version": "nuplan"})}, open(out_infos, "wb"))
json.dump({i["token"]: i["cams"]["CAM_F0"]["data_path"].split("sensor_blobs/")[-1] for i in out},
          open(out_tokens, "w"))
short = [(s, g, w) for s, g, w in report if g != w]
print(f"[shard_infos] {len(groups)} scenario(s), {len(out)} frames -> {out_infos}")
if short:
    print(f"[shard_infos] {len(short)} scenario(s) short of the manifest: {short[:5]}")
