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

Scenarios whose frames are all on disk already are dropped from the shard. This
stage has been restarted several times (a bad ann_file, then a CPU request that
would not schedule), and without the skip every restart regenerates hours of
finished work. Skipping is at SCENARIO granularity, never at frame: generation
is autoregressive, so resuming mid-scenario would produce frames conditioned on
a different history than the ones already on disk.
"""
import json, os, pickle, sys

RQE = "/avl-west/render_quality_eval"
INFOS = f"{RQE}/infos/nuplan_infos_all.pkl"
MANIFEST = f"{RQE}/manifest.json"
CAPTIONS = f"{RQE}/captions.json"
RENDER_ROOT = os.environ.get("WD_RENDER_ROOT", f"{RQE}/render_raw/drivearena")

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

out, groups, report, expected, n_skip = [], [], [], [], 0
for sid in sorted(want_sids):
    sc = man.get(sid)
    if sc is None:
        report.append((sid, 0, 0)); continue
    if all(os.path.exists(os.path.join(RENDER_ROOT, f["data_path"])) for f in sc["frames"]):
        n_skip += 1; continue
    # Match on the CAM_F0 image token ALONE. A token is unique within a log, so
    # the timestamp window this used to also apply was redundant -- and it was
    # wrong: the manifest's t0/t1 are camera timestamps while infos carries the
    # lidar_pc timestamp, and the two differ by half a camera period (50ms at
    # 10Hz). The lidar stamp of a scenario's first frame therefore fell just
    # below t0, silently dropping frame 0 of 126 scenarios.
    want_tokens = {f["image_token"] for f in sc["frames"]}
    win = [i for i in by_log.get(sc["log"], []) if camf0(i) in want_tokens]
    win.sort(key=lambda e: e["timestamp"])
    if not win:
        report.append((sid, 0, len(sc["frames"]))); continue
    cap = caps.get(sid) or caps.get(sc["map_location"]) or ""
    for i in win:
        i["description"] = cap
        i["is_first_frame"] = False
    out.extend(win)
    expected.extend(f["data_path"] for f in sc["frames"])
    groups.append([i["token"] for i in win])
    report.append((sid, len(win), len(sc["frames"])))

pickle.dump({"infos": out, "scene_tokens": groups,
             "metadata": data.get("metadata", {"version": "nuplan"})}, open(out_infos, "wb"))
json.dump({i["token"]: i["cams"]["CAM_F0"]["data_path"].split("sensor_blobs/")[-1] for i in out},
          open(out_tokens, "w"))
with open(out_tokens + ".expected", "w") as f:
    f.write("\n".join(expected))
short = [(s, g, w) for s, g, w in report if g != w]
print(f"[shard_infos] {len(groups)} scenario(s) to do, {n_skip} already complete, "
      f"{len(out)} frames -> {out_infos}")
if short:
    print(f"[shard_infos] {len(short)} scenario(s) short of the manifest: {short[:5]}")
if not groups:
    print("SHARD_ALREADY_COMPLETE")
