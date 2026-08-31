#!/usr/bin/env python3
"""Pin the frame set both renderers must cover, once, before anything generates.

Runs ON THE POD (the Mac cannot read CephFS). Writes
/avl-west/render_quality_eval/manifest.json:

    {"scenarios":[{"sid","log","t0","t1","map_location",
                   "frames":[{"i","ts","scene_token","image_token",
                              "data_path","gt","is_navtest"}, ...]}, ...]}

Design notes that matter for comparability:

* Scenarios are the navsafe_5s_500 entries whose four 5 s reconstructions ALL
  exist -- anything less cannot be rendered by our side at all.
* Scenarios on a log inside DriveArena's nuPlan training split are DROPPED.
  Leaving them in would hand the generative side scenes it was trained on.
* `frames` is every 2 Hz navsim frame in the 20 s window, not just the navtest
  tokens: FID and FVD only need images, so restricting them to navtest would
  throw away 70% of the sample for no reason. `is_navtest` marks the subset
  FDpi^k must use, since only those frames can build a valid policy input.
* `data_path` is `<log>/CAM_F0/<image_token>.jpg` -- the ORIGINAL sensor-blob
  filename. Both render sets write to that exact path, which is what makes
  "same frame" mechanical rather than a matter of trust.
"""
import csv, json, os, pickle, sys
import yaml

CORPUS = "/avl-west/navsafe_5s_500"
UE = "/avl-west/drivearena_bench/unified_evaluator"
WD = "/avl-west/drivearena_bench/DriveArena/WorldDreamer"
LOGS = "/avl-west/navsim/test_navsim_logs/test"
BLOBS = "/avl-west/navsim/test_sensor_blobs/test"
OUT = "/avl-west/render_quality_eval/manifest.json"

navtest = set(yaml.safe_load(open(
    f"{UE}/navsim/planning/script/config/common/train_test_split/scene_filter/navtest.yaml"))["tokens"])
da = yaml.safe_load(open(f"{WD}/tools/data_converter/nuplan.yaml"))["log_splits"]
da_train = set(da["dreamer_train"]) | set(da["dreamer_val"])

rows = [r for r in csv.reader(open("/avl-west/navsafe_dev/scenes_500.tsv"), delimiter="\t")
        if len(r) >= 4 and not r[0].startswith("#")]
recon = [r for r in rows if all(os.path.exists(
    f"{CORPUS}/{r[0]}s{k}/output_5cam/{r[0]}s{k}/artifacts/last.usdz") for k in (1, 2, 3, 4))]
clean = [r for r in recon if r[1] not in da_train]
dropped = len(recon) - len(clean)

by_log = {}
for r in clean:
    by_log.setdefault(r[1], []).append(r)

scenarios, n_missing_gt = [], 0
for log in sorted(by_log):
    p = f"{LOGS}/{log}.pkl"
    if not os.path.exists(p):
        print(f"  !! no navsim log pkl for {log}, skipping its scenarios", file=sys.stderr)
        continue
    frames_all = sorted(pickle.load(open(p, "rb")), key=lambda f: f["timestamp"])
    for r in by_log[log]:
        sid, t0, t1 = r[0], int(r[2]), int(r[3])
        win = [f for f in frames_all if t0 <= f["timestamp"] <= t1]
        if not win:
            continue
        fr = []
        for i, f in enumerate(win):
            dp = f["cams"]["CAM_F0"]["data_path"]
            gt = f"{BLOBS}/{dp}"
            if not os.path.exists(gt):
                n_missing_gt += 1
                continue
            fr.append(dict(i=i, ts=f["timestamp"], scene_token=f["token"],
                           image_token=os.path.basename(dp).split(".")[0],
                           data_path=dp, gt=gt, is_navtest=f["token"] in navtest))
        scenarios.append(dict(sid=sid, log=log, t0=t0, t1=t1,
                              map_location=win[0]["map_location"],
                              tags=r[4] if len(r) > 4 else "",
                              n_frames=len(fr),
                              n_navtest=sum(x["is_navtest"] for x in fr),
                              frames=fr))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump({"scenarios": scenarios,
           "_note": "frame set both renderers must cover; is_navtest marks the FDpi subset"},
          open(OUT, "w"))
nf = sum(s["n_frames"] for s in scenarios)
nt = sum(s["n_navtest"] for s in scenarios)
print(f"scenarios with 4/4 recon : {len(recon)}")
print(f"dropped (DriveArena train logs): {dropped}")
print(f"kept                     : {len(scenarios)} scenarios over {len(by_log)} logs")
print(f"frames (2 Hz)            : {nf}    <- FID/FVD")
print(f"  navtest tokens         : {nt}    <- FDpi^k")
print(f"missing GT jpgs          : {n_missing_gt}")
print(f"wrote {OUT}")
