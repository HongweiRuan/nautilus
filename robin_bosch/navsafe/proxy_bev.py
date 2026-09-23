"""Per-scenario breakdown + static BEV of Robin's best-PDMS before/after (LQR) vs DrivoR on the NavSafe proxy set.

Run inside a NavSafe worker pod (needs /root/ns and ns-venv):
  PYTHONPATH=/root/ns:/avl-west/navsafe_eval/aug_zoo/SimScale/nuplan-devkit PY123D_RECENTER=1 \
    /root/ns-venv/bin/python proxy_bev.py OUT_DIR TOKEN [TOKEN ...]

Driven paths are vehicle_states.npy (SIM frame); each is shifted to world by the offset that puts its frame 0 on the
logged ego pose (plot_refine_bev.py does the same). Map = the scenario's py123d map_features.
"""
import json, os, sys
from types import SimpleNamespace

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon
import numpy as np

from nexussim.env.loaders.py123d import Py123DLoader

ROOT = "/avl-west/navsafe_eval"
OURS = f"{ROOT}/robin_drivor_action_proxy28/lqr"
CELLS = json.load(open(f"{ROOT}/reactivity_nohazard_eval/20260917-v1/cells.json"))
LEAF = {c["token"]: c["leaf"] for c in CELLS}
RECIPE_DIR = "/root/ns/nexussim/navsafe/recipes/benchmark"

RUNS = [  # label, dir resolver, colour, style
    ("DrivoR s0/s1024 (lqr_outputs)", lambda t: f"{ROOT}/lqr_outputs/drivor/seed0/{t}", "tab:blue", "-"),
    ("DrivoR s1 (final_outputs)", lambda t: f"{ROOT}/final_outputs/drivor/seed1/{t}", "tab:cyan", "--"),
    ("best_before (LQR)", lambda t: f"{OURS}/drivor_action_best_before/seed0/{t}", "tab:orange", "-"),
    ("best_after (LQR)", lambda t: f"{OURS}/drivor_action_best_after/seed0/{t}", "tab:green", "-"),
]
MAP_STYLE = {
    "LANE_SURFACE_STREET": ("#e6e6e6", 1), "INTERSECTION": ("#d9d9d9", 2), "CARPARK_AREA": ("#f2efe6", 0),
    "CROSSWALK": ("#c9d7f0", 3),
}


def load_cell(d):
    m = json.load(open(f"{d}/navsafe_metrics.json"))
    st = np.load(f"{d}/vehicle_states.npy")
    b = m.get("driving_score_breakdown") or {}
    ch = {c["channel"]: c for c in b.get("channels", [])}
    t = m.get("termination") or {}
    return dict(states=st, ds=m["metrics"]["driving_score"], rc=b.get("route_completion_pct"), pen=b.get("penalty"),
                term=t.get("reason"), frame=t.get("frame"), detail=t.get("detail") or "",
                warm=m["frames"]["warmup_excluded"], frames=m["frames"]["total"],
                off_route=(ch.get("outside_route_lanes") or {}).get("pct"),
                veh=(ch.get("collisions_vehicle") or {}).get("count"), ped=(ch.get("collisions_pedestrian") or {}).get("count"),
                lay=(ch.get("collisions_layout") or {}).get("count"), red=(ch.get("red_light") or {}).get("count"))


def recipe_of(t):
    for f in os.listdir(RECIPE_DIR):
        if f.endswith(f".{t}.yaml"):
            return f.split(".")[0]
    return "-"


def main(out, tokens):
    os.makedirs(out, exist_ok=True)
    rows = []
    for t in tokens:
        sc = Py123DLoader().load(SimpleNamespace(py123d_data_root=f"{ROOT}/dataset/{t}/arrow", start_scenario_index=0,
                                                 scenario_id=None, py123d_require_map=True, remove_agents=False))
        sdc = sc["metadata"].get("sdc_id") or "ego"
        logged = np.asarray(sc["tracks"][sdc]["state"]["position"])[:, :2]
        cells = {}
        for label, res, col, ls in RUNS:
            d = res(t)
            if os.path.exists(f"{d}/navsafe_metrics.json"):
                c = load_cell(d); c["world"] = c["states"][:, :2] + (logged[0] - c["states"][0, :2]); cells[label] = c
                rows.append((t, LEAF.get(t, "?"), recipe_of(t), label, c))
        pts = np.vstack([logged] + [c["world"] for c in cells.values()])
        lo, hi = pts.min(0) - 25, pts.max(0) + 25
        fig, ax = plt.subplots(figsize=(9, 9))
        for f in sc["map_features"].values():
            ty = f.get("type", "")
            poly = f.get("polygon")
            if ty in MAP_STYLE and poly is not None and len(poly) >= 3:
                p = np.asarray(poly)[:, :2]
                if (p.max(0) < lo).any() or (p.min(0) > hi).any():
                    continue
                colr, z = MAP_STYLE[ty]
                ax.add_patch(Polygon(p, closed=True, facecolor=colr, edgecolor="#bdbdbd", lw=0.3, zorder=z))
            elif "LINE" in ty and f.get("polyline") is not None:
                p = np.asarray(f["polyline"])[:, :2]
                if (p.max(0) < lo).any() or (p.min(0) > hi).any():
                    continue
                ax.plot(p[:, 0], p[:, 1], color="#9e9e9e" if "WHITE" in ty else "#cfcfcf", lw=0.5, zorder=4)
        ax.plot(logged[:, 0], logged[:, 1], color="k", ls=":", lw=1.2, zorder=5, label="logged ego (log)")
        ax.plot(*logged[0], "k^", ms=9, zorder=9)
        for label, res, col, ls in RUNS:
            if label not in cells:
                continue
            c = cells[label]; w = c["world"]
            ax.plot(w[:, 0], w[:, 1], color=col, ls=ls, lw=2.2, zorder=6,
                    label=f"{label}: DS {c['ds']:.1f}, {c['term']}@{c['frame']}")
            mk = "o" if c["term"] == "goal_reached" else "X"
            ax.plot(w[-1, 0], w[-1, 1], mk, color=col, ms=11, mec="k", zorder=8)
        ax.set_xlim(lo[0], hi[0]); ax.set_ylim(lo[1], hi[1]); ax.set_aspect("equal")
        ax.set_title(f"{t}  leaf {LEAF.get(t, '?')}  recipe {recipe_of(t)}\n"
                     "▲ start   ● goal reached   ✕ terminated", fontsize=10)
        ax.legend(loc="best", fontsize=7.5, framealpha=0.9)
        ax.set_xlabel("x [m]"); ax.set_ylabel("y [m]")
        fig.tight_layout(); fig.savefig(f"{out}/{t}.png", dpi=110); plt.close(fig)
        print("wrote", f"{out}/{t}.png", flush=True)
    with open(f"{out}/breakdown.tsv", "w") as fh:
        fh.write("token\tleaf\trecipe\trun\tDS\troute_completion_pct\tpenalty\ttermination\tframe\tdetail\twarmup\tframes\t"
                 "outside_route_pct\tveh_collisions\tped_collisions\tlayout_collisions\tred_light\n")
        for t, leaf, rec, label, c in rows:
            fh.write("\t".join(str(x) for x in (t, leaf, rec, label, round(c["ds"], 2), c["rc"], c["pen"], c["term"], c["frame"],
                                                c["detail"], c["warm"], c["frames"], c["off_route"], c["veh"], c["ped"], c["lay"], c["red"])) + "\n")
    print("wrote", f"{out}/breakdown.tsv")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
