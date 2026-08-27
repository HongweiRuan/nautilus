#!/usr/bin/env python3
"""Fold the converter's train+val pkls into one corpus-wide infos file.

The split.yaml puts one log on the train side only because the converter
crashes on an empty train split; nothing downstream cares which side a log came
out of, so they are merged here and re-grouped per shard later.
"""
import glob, os, pickle

RQE = "/avl-west/render_quality_eval"
W = f"{RQE}/infos/work"
infos, meta = [], None
for name in ("nuplan_infos_train.pkl", "nuplan_infos_val.pkl"):
    p = f"{W}/{name}"
    if not os.path.exists(p):
        print(f"  (no {name})"); continue
    d = pickle.load(open(p, "rb"))
    infos.extend(d["infos"]); meta = meta or d.get("metadata")
out = f"{RQE}/infos/nuplan_infos_all.pkl"
pickle.dump({"infos": infos, "scene_tokens": [], "metadata": meta or {"version": "nuplan"}},
            open(out, "wb"))
print(f"[merge] {len(infos)} infos -> {out}")
