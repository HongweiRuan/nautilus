"""Overlay every replan's plan (plan_records.json) on the driven path, to tell a bad plan from bad tracking.
Same env as proxy_bev.py.  python proxy_plans.py OUT_DIR RUN(best_before|best_after) TOKEN [TOKEN ...]"""
import json, math, sys
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
sys.path.insert(0, "/tmp")
import proxy_bev as pb
from types import SimpleNamespace
from nexussim.env.loaders.py123d import Py123DLoader

out, run, toks = sys.argv[1], sys.argv[2], sys.argv[3:]
for t in toks:
    sc = Py123DLoader().load(SimpleNamespace(py123d_data_root=f"{pb.ROOT}/dataset/{t}/arrow", start_scenario_index=0,
                                             scenario_id=None, py123d_require_map=True, remove_agents=False))
    logged = np.asarray(sc["tracks"][sc["metadata"].get("sdc_id") or "ego"]["state"]["position"])[:, :2]
    d = f"{pb.OURS}/drivor_action_{run}/seed0/{t}"
    st = np.load(f"{d}/vehicle_states.npy"); shift = logged[0] - st[0, :2]; w = st[:, :2] + shift
    pr = json.load(open(f"{d}/plan_records.json"))["predictions"]
    lo, hi = w.min(0) - 20, w.max(0) + 20
    fig, ax = plt.subplots(figsize=(8, 8))
    for f in sc["map_features"].values():
        ty = f.get("type", ""); poly = f.get("polygon")
        if ty in pb.MAP_STYLE and poly is not None and len(poly) >= 3:
            p = np.asarray(poly)[:, :2]
            if (p.max(0) < lo).any() or (p.min(0) > hi).any(): continue
            ax.add_patch(pb.Polygon(p, closed=True, facecolor=pb.MAP_STYLE[ty][0], edgecolor="#bdbdbd", lw=0.3, zorder=1))
    ax.plot(logged[:, 0], logged[:, 1], "k:", lw=1.2, label="logged ego")
    cm = plt.get_cmap("plasma")
    for i, r in enumerate(pr):
        x0, y0, _ = r["ego_position"]; h = r["ego_heading"]; e = np.asarray(r["selected_ego"])  # [lateral, forward]
        lat, fwd = e[:, 0], e[:, 1]
        px = x0 + fwd * math.cos(h) - lat * math.sin(h) + shift[0]; py = y0 + fwd * math.sin(h) + lat * math.cos(h) + shift[1]
        ax.plot(np.r_[x0 + shift[0], px], np.r_[y0 + shift[1], py], "-", color=cm(i / max(1, len(pr) - 1)), lw=1.3, alpha=0.9,
                label="plans (frame 0 → last, dark → bright)" if i == 0 else None)
    ax.plot(w[:, 0], w[:, 1], color="tab:green", lw=2.5, label=f"executed ({run}, LQR)")
    ax.plot(*w[-1], "X", color="tab:red", ms=12, mec="k", label="termination")
    ax.set_xlim(lo[0], hi[0]); ax.set_ylim(lo[1], hi[1]); ax.set_aspect("equal"); ax.legend(fontsize=8)
    ax.set_title(f"{t} leaf {pb.LEAF.get(t)}: {len(pr)} replans of {run} vs the executed LQR path", fontsize=10)
    fig.tight_layout(); fig.savefig(f"{out}/{t}_plans_{run}.png", dpi=110); plt.close(fig); print("wrote", t)
