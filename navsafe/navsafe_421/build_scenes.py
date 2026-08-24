#!/usr/bin/env python3
"""Build the navhard-421 scene manifest: token -> (nuPlan log, t0_us, t1_us).

Reproduces the BridgeSim openscene converter's window for each scene so the
NexusSim native-10Hz-nuPlan pipeline (convert_nuplan10hz / arrow-dataset) gets
the SAME [t0,t1] the scene was defined with.

Per scene (converter logic, run with --num-future-frames-extract 40):
  token = current frame's lidar_pc token (index num_history_frames-1 in window)
  window = frames[i_cur - (NUM_HIST-1) : i_cur - (NUM_HIST-1) + NUM_HIST + FUT_EXTRACT]
  t0 = window[0].timestamp, t1 = window[-1].timestamp, log = frame.log_name
The 421 target tokens are the sd_<token> dirs the converter actually emitted.
"""
import pickle, glob, os, sys

NAVSIM = "/avl-west/navsim/test_navsim_logs/test"
BRIDGE = "/hugsim-storage/bridgesim_converter_navhard"
OUT = "/avl-west/navsafe_dev/navhard421_scenes.tsv"
NUM_HIST = 4        # navhard_two_stage.yaml num_history_frames
FUT_EXTRACT = 40    # convert command --num-future-frames-extract
HIST_OFF = NUM_HIST - 1              # token sits at index 3 of the window
WIN = NUM_HIST + FUT_EXTRACT         # 44 frames total

targets = {d[3:] for d in os.listdir(BRIDGE) if d.startswith("sd_")}
print(f"target tokens (sd_ dirs): {len(targets)}", flush=True)

resolved = {}   # token -> (log, t0, t1)
missing_edge = []
for pkl in sorted(glob.glob(NAVSIM + "/*.pkl")):
    frames = pickle.load(open(pkl, "rb"))
    frames = sorted(frames, key=lambda f: f["timestamp"])
    idx = {f["token"]: i for i, f in enumerate(frames)}
    for tok in targets & idx.keys():
        i_cur = idx[tok]
        s = i_cur - HIST_OFF
        e = s + WIN - 1
        if s < 0 or e >= len(frames):
            missing_edge.append(tok); continue
        resolved[tok] = (frames[i_cur]["log_name"],
                         int(frames[s]["timestamp"]),
                         int(frames[e]["timestamp"]))

print(f"resolved {len(resolved)}/{len(targets)}  edge-truncated {len(missing_edge)}", flush=True)
unresolved = targets - set(resolved) - set(missing_edge)
if unresolved:
    print(f"UNRESOLVED (not in any navsim pkl): {len(unresolved)} e.g. {list(unresolved)[:5]}", flush=True)

# cross-check the known 00c1e4eb window
CK = "00c1e4eb4a045f20"
if CK in resolved:
    log, t0, t1 = resolved[CK]
    print(f"[check] {CK}: {log} [{t0},{t1}] dur={(t1-t0)/1e6:.2f}s "
          f"(known: 2021.10.06.07.26.10_veh-52_00953_01126 "
          f"[1633506278200211,1633506299700143] 21.50s)", flush=True)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as fh:
    for tok in sorted(resolved):
        log, t0, t1 = resolved[tok]
        fh.write(f"{tok}\t{log}\t{t0}\t{t1}\n")
print(f"wrote {OUT} ({len(resolved)} rows)", flush=True)
