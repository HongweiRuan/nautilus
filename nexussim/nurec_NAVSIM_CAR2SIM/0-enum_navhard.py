#!/usr/bin/env python3
"""Enumerate the 421 navhard MetaDrive scenario descriptors ->
(token, nuplan_log, t0_us, t1_us, db_split, map, ready). Writes
/avl-west/navsafe/navhard_scenes.tsv (the orchestrator work list)."""
import pickle, glob, os, sys, types
from collections import Counter

NAVHARD = "/avl-west/navsim/navhard_md_logs"
SPLITS = "/avl-west/nuplan/nuplan-v1.1/splits"
MAPS = "/avl-west/nuplan/maps"
OUT = "/avl-west/navsafe/navhard_scenes.tsv"

# ---- stub metadrive so we can unpickle without the exact version ----
class _StubDict(dict): pass
def _mk(mod, names=()):
    m = types.ModuleType(mod)
    for n in names: setattr(m, n, _StubDict)
    sys.modules[mod] = m; return m
for mod in ["metadrive", "metadrive.scenario", "metadrive.type", "metadrive.utils",
            "metadrive.utils.data_buffer", "metadrive.scenario.scenario_description"]:
    _mk(mod)
class Tolerant(pickle.Unpickler):
    def find_class(self, module, name):
        try: return super().find_class(module, name)
        except Exception:
            m = sys.modules.get(module) or _mk(module)
            if not hasattr(m, name): setattr(m, name, _StubDict)
            return getattr(m, name)

# available nuplan dbs per split + available maps
split_dbs = {}
for sp in sorted(os.listdir(SPLITS)):
    p = f"{SPLITS}/{sp}"
    if os.path.isdir(p):
        split_dbs[sp] = set(os.path.splitext(f)[0] for f in os.listdir(p) if f.endswith(".db"))
avail_maps = set(os.listdir(MAPS)) if os.path.isdir(MAPS) else set()

dirs = sorted(glob.glob(f"{NAVHARD}/sd_*"))
rows, problems = [], []
for d in dirs:
    sd = os.path.basename(d)
    pk = glob.glob(f"{d}/*/*.pkl")
    if not pk: problems.append((sd, "no-pkl")); continue
    try:
        obj = Tolerant(open(pk[0], "rb")).load()
        meta = obj["metadata"]
        tok = meta["scenario_id"]; log = meta["log_name"]; mp = meta.get("map", "?")
        ts = [int(fr["timestamp"]) for fr in meta["frame_info"] if fr.get("timestamp")]
    except Exception as e:
        problems.append((sd, f"parse:{type(e).__name__}")); continue
    if not ts: problems.append((sd, "no-ts")); continue
    split = next((sp for sp, dbs in split_dbs.items() if log in dbs), None)
    map_ok = any(mp in m for m in avail_maps) if mp != "?" else False
    ready = "Y" if split else "N"
    rows.append((tok, log, min(ts), max(ts), split or "MISSING", mp, "Y" if map_ok else "N", ready, len(ts)))

os.makedirs("/avl-west/navsafe", exist_ok=True)
with open(OUT, "w") as f:
    f.write("token\tlog\tt0\tt1\tdb_split\tmap\tmap_ok\tdb_ready\tnframes\n")
    for r in rows: f.write("\t".join(map(str, r)) + "\n")

ready = [r for r in rows if r[7] == "Y"]
print(f"navhard dirs={len(dirs)} parsed={len(rows)} problems={len(problems)}")
print(f"DB-ready (recon can run): {len(ready)} / {len(rows)}")
print(f"map distribution: {dict(Counter(r[5] for r in rows))}")
print(f"db_split distribution: {dict(Counter(r[4] for r in rows))}")
print(f"map_ok among ready: {Counter(r[6] for r in ready)}")
print(f"WROTE {OUT}")
if problems: print("problems sample:", problems[:6])
miss = [r for r in rows if r[7] == "N"]
if miss: print("db-missing logs sample:", [(r[0], r[1]) for r in miss[:6]])
