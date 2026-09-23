"""Proxy-28 report: per-scenario sub-metrics for every run + one BEV per scenario with every run's executed path.

Run inside a NavSafe worker pod:
  PYTHONPATH=/root/ns:/avl-west/navsafe_eval/aug_zoo/SimScale/nuplan-devkit PY123D_RECENTER=1 \
    /root/ns-venv/bin/python proxy_report.py OUT_DIR

Runs: Robin best_before/best_after x {lqr, pure_pursuit} (seed 0, this campaign); DrivoR history from metrics_all
(seed0 = seed1024 = lqr_outputs, seed1 = final_outputs, all LQR); DrivoR re-run in this campaign x {lqr, pure_pursuit}
(where finished). Driven paths = vehicle_states.npy shifted to world by the frame-0 offset to the logged ego pose.
"""
import glob, json, os, re, statistics as st, sys
from types import SimpleNamespace

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon
import numpy as np

from nexussim.env.loaders.py123d import Py123DLoader

ROOT = "/avl-west/navsafe_eval"
P28 = f"{ROOT}/robin_drivor_action_proxy28"
TOKENS = [l.strip() for l in open("/cfg/proxy28_tokens.txt") if l.strip()]
LEAF = {c["token"]: c["leaf"] for c in json.load(open(f"{ROOT}/reactivity_nohazard_eval/20260917-v1/cells.json"))}
RECIPES = {m.group(1): f.split(".")[0] for f in os.listdir("/root/ns/nexussim/navsafe/recipes/benchmark")
           if (m := re.search(r"\.([0-9a-f]{16})\.yaml$", f))}
EPDMS_KEYS = ["route_completion", "epdms", "no_at_fault_collisions", "drivable_area_compliance",
              "driving_direction_compliance", "traffic_light_compliance", "time_to_collision_within_bound",
              "lane_keeping", "history_comfort", "extended_comfort", "ego_progress", "collision_count", "avg_speed"]


def hist(seed):
    def res(t):
        f = f"{ROOT}/metrics_all/drivor/{seed}/{t}.json"
        return json.load(open(f)).get("source") if os.path.exists(f) else None
    return res


# label, dir resolver, colour, linestyle, linewidth
RUNS = [
    ("hist_seed_0", hist("seed0"), "#7f7f7f", "-", 1.6),
    ("hist_seed_1", hist("seed1"), "#7f7f7f", ":", 1.6),
    ("hist_seed_1024", hist("seed1024"), "#b0b0b0", "-.", 1.2),
    ("drivor_pp", lambda t: f"{P28}/pure_pursuit/drivor/seed0/{t}", "tab:blue", "--", 2.0),
    ("best_before_lqr", lambda t: f"{P28}/lqr/drivor_action_best_before/seed0/{t}", "tab:orange", "-", 2.2),
    ("best_before_pp", lambda t: f"{P28}/pure_pursuit/drivor_action_best_before/seed0/{t}", "tab:orange", "--", 2.2),
    ("best_after_lqr", lambda t: f"{P28}/lqr/drivor_action_best_after/seed0/{t}", "tab:green", "-", 2.2),
    ("best_after_pp", lambda t: f"{P28}/pure_pursuit/drivor_action_best_after/seed0/{t}", "tab:green", "--", 2.2),
]
MAP_STYLE = {"LANE_SURFACE_STREET": "#e6e6e6", "INTERSECTION": "#d9d9d9", "CARPARK_AREA": "#f2efe6", "CROSSWALK": "#c9d7f0"}


def load(d):
    if not d or not os.path.exists(f"{d}/navsafe_metrics.json"):
        return None
    m = json.load(open(f"{d}/navsafe_metrics.json"))
    if m.get("status") != "scored":
        return None
    b = m.get("driving_score_breakdown") or {}
    ch = {c["channel"]: c for c in b.get("channels", [])}
    t = m.get("termination") or {}
    out = dict(DS=m["metrics"]["driving_score"], success=int(bool(m["metrics"].get("success"))), comfort=m["metrics"].get("comfort"),
               RC_pct=b.get("route_completion_pct"), penalty=b.get("penalty"), termination=t.get("reason"), term_frame=t.get("frame"),
               detail=t.get("detail") or "", frames=m["frames"]["total"], warmup=m["frames"]["warmup_excluded"],
               off_route_pct=(ch.get("outside_route_lanes") or {}).get("pct"),
               coll_vehicle=(ch.get("collisions_vehicle") or {}).get("count"), coll_ped=(ch.get("collisions_pedestrian") or {}).get("count"),
               coll_layout=(ch.get("collisions_layout") or {}).get("count"), red_light=(ch.get("red_light") or {}).get("count"))
    log = d + ".log"
    if os.path.exists(log):
        s = open(log, errors="ignore").read()
        mm = re.search(r"\[eval_py123d\] DONE\. results=.*?'metrics': \{(.*?)\}", s)
        if mm:
            for k in EPDMS_KEYS:
                v = re.search(r"'" + k + r"': ([-\d.eE]+|True|False)", mm.group(1))
                out[k] = (round(float(v.group(1)), 4) if v and v.group(1) not in ("True", "False") else (v.group(1) if v else None))
    vs = f"{d}/vehicle_states.npy"
    out["states"] = np.load(vs) if os.path.exists(vs) else None
    return out


def bev(t, cells, out):
    sc = Py123DLoader().load(SimpleNamespace(py123d_data_root=f"{ROOT}/full_test/{t}/arrow", start_scenario_index=0,
                                             scenario_id=None, py123d_require_map=True, remove_agents=False))
    logged = np.asarray(sc["tracks"][sc["metadata"].get("sdc_id") or "ego"]["state"]["position"])[:, :2]
    paths = {k: c["states"][:, :2] + (logged[0] - c["states"][0, :2]) for k, c in cells.items() if c and c["states"] is not None}
    pts = np.vstack([logged] + list(paths.values()))
    lo, hi = pts.min(0) - 20, pts.max(0) + 20
    fig, ax = plt.subplots(figsize=(10, 10))
    for f in sc["map_features"].values():
        ty = f.get("type", ""); poly = f.get("polygon")
        if ty in MAP_STYLE and poly is not None and len(poly) >= 3:
            p = np.asarray(poly)[:, :2]
            if (p.max(0) < lo).any() or (p.min(0) > hi).any():
                continue
            ax.add_patch(Polygon(p, closed=True, facecolor=MAP_STYLE[ty], edgecolor="#bdbdbd", lw=0.3, zorder=1))
        elif "LINE" in ty and f.get("polyline") is not None:
            p = np.asarray(f["polyline"])[:, :2]
            if (p.max(0) < lo).any() or (p.min(0) > hi).any():
                continue
            ax.plot(p[:, 0], p[:, 1], color="#bdbdbd", lw=0.4, zorder=2)
    ax.plot(logged[:, 0], logged[:, 1], color="k", ls=(0, (1, 2)), lw=1.0, zorder=3, label="logged ego")
    ax.plot(*logged[0], "k^", ms=10, zorder=10)
    for label, _, col, ls, lw in RUNS:
        if label not in paths:
            continue
        w = paths[label]; c = cells[label]
        ax.plot(w[:, 0], w[:, 1], color=col, ls=ls, lw=lw, zorder=5, alpha=0.9,
                label=f"{label}: DS {c['DS']:.1f}, {c['termination']}@{c['term_frame']}")
        ax.plot(w[-1, 0], w[-1, 1], "o" if c["termination"] == "goal_reached" else "X", color=col, ms=10, mec="k", zorder=9)
    ax.set_xlim(lo[0], hi[0]); ax.set_ylim(lo[1], hi[1]); ax.set_aspect("equal")
    ax.set_title(f"{t}   leaf {LEAF.get(t, '?')}   recipe {RECIPES.get(t, '-')}\n▲ start   ● goal reached   ✕ terminated   "
                 "solid = lqr, dashed = pp; hist_seed_* = DrivoR history (lqr)", fontsize=10)
    ax.legend(loc="best", fontsize=7, framealpha=0.9)
    fig.tight_layout(); fig.savefig(f"{out}/bev/{t}.png", dpi=100); plt.close(fig)


def main(out):
    os.makedirs(f"{out}/bev", exist_ok=True)
    cols = ["DS", "success", "RC_pct", "penalty", "termination", "term_frame", "detail", "frames", "warmup", "off_route_pct",
            "coll_vehicle", "coll_ped", "coll_layout", "red_light", "comfort"] + EPDMS_KEYS
    rows = []
    for t in TOKENS:
        cells = {label: load(res(t)) for label, res, *_ in RUNS}
        for label, c in cells.items():
            if c:
                rows.append([t, LEAF.get(t, "?"), RECIPES.get(t, "-"), label] + [c.get(k) for k in cols])
        bev(t, cells, out)
        print("done", t, flush=True)
    with open(f"{out}/table.tsv", "w") as fh:
        fh.write("\t".join(["token", "leaf", "recipe", "model"] + cols) + "\n")
        for r in rows:
            fh.write("\t".join("" if x is None else str(x) for x in r) + "\n")
    print("wrote", f"{out}/table.tsv")


if __name__ == "__main__":
    main(sys.argv[1])
