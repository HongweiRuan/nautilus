#!/usr/bin/env python3
"""Export the map and actors a scenario needs to draw its own BEV.

The evaluator's own `topdown.png` is ego-CENTRED: the ego is pinned at the frame
centre and the world slides under it, so the one thing the demo exists to show --
that the ego was moved -- is defined away. This writes the geometry instead, in
the BASELINE ego's frame, and the page draws the picture. Vector, so it is sharp
at any zoom and any device pixel ratio, and the plans and driven paths land in
the same coordinate system as the road.

Everything is expressed in the baseline ego frame at the hand-off:
``[lateral (+left), forward]`` metres. That is the frame the panel already plots
in, so nothing has to be transformed twice.

Runs ON THE CLUSTER: it needs nexussim and the scenario's Arrow.

    kubectl exec -n cogrob <pod> -- python3 /path/export_bev.py <token> <out_dir>
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

RUN = Path("/avl-west/runs/20260905-handoff-perturb-demo/eval/seed0")
RECIPES = Path("/root/ns/nexussim/navsafe/recipes/benchmark")


def data_root_for(token: str) -> tuple[Path, int]:
    """The Arrow the run scored against, and its hand-off frame.

    Mirrors the worker: a token with a recipe FILE is scored against the
    published window; the hand-off is the RESOLVED one, which for a recipe that
    inserts nothing is the flag's 20 and not the recipe's 8. Rather than redo
    that resolution, read it back out of a cell the run already wrote.
    """
    rel = Path("/avl-west/navsafe_release") / token / "arrow"
    mirror = Path("/avl-west/navsafe_dev/full_test_mirror") / token / "arrow"
    root = rel if list(RECIPES.glob(f"*.{token}.yaml")) and rel.is_dir() else mirror
    handoff = 20
    for hit in RUN.glob(f"*/{token}"):
        for cell in sorted(hit.glob("base/*/plan_records.json")):
            handoff = int(json.loads(cell.read_text())["handoff_frame"])
            break
        break
    return root, handoff


def to_base(pts: np.ndarray, origin: np.ndarray, heading: float) -> np.ndarray:
    """World XY -> baseline-ego XY, as [lateral(+left), forward]."""
    c, s = math.cos(-heading), math.sin(-heading)
    d = np.asarray(pts, dtype=float)[:, :2] - origin[:2]
    return np.column_stack([s * d[:, 0] + c * d[:, 1], c * d[:, 0] - s * d[:, 1]])


def simplify(xy: np.ndarray, tol: float) -> np.ndarray:
    """Ramer-Douglas-Peucker. A city map carries far more vertices than a 700 px
    canvas can show, and shipping them all is bytes for nothing."""
    if len(xy) < 3:
        return xy
    stack, keep = [(0, len(xy) - 1)], np.zeros(len(xy), bool)
    keep[0] = keep[-1] = True
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        p, q = xy[i], xy[j]
        seg = q - p
        L = math.hypot(*seg)
        if L < 1e-9:
            d = np.linalg.norm(xy[i + 1:j] - p, axis=1)
        else:
            # 2-D cross product written out: np.cross on 2-vectors is deprecated
            # in NumPy 2 and this is the same number.
            v = xy[i + 1:j] - p
            d = np.abs(seg[0] * v[:, 1] - seg[1] * v[:, 0]) / L
        k = int(np.argmax(d))
        if d[k] > tol:
            keep[i + 1 + k] = True
            stack += [(i, i + 1 + k), (i + 1 + k, j)]
    return xy[keep]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("token")
    ap.add_argument("out_dir")
    ap.add_argument("--radius", type=float, default=70.0,
                    help="metres around the baseline ego to keep")
    ap.add_argument("--tol", type=float, default=0.15,
                    help="polyline simplification tolerance, metres")
    args = ap.parse_args()

    from nexussim.navsafe.editing.host import load_host_scenario
    from nexussim.scenario.type import MetaDriveType
    from nexussim.core.track_dims import track_dims

    root, handoff = data_root_for(args.token)
    sd, scene = load_host_scenario(root, scene_index=0, require_map=True)

    meta = sd.get("metadata", {}) or {}
    sdc = str(meta.get("sdc_id", "ego"))
    ego_state = sd["tracks"][sdc]["state"]
    origin = np.asarray(ego_state["position"], dtype=float)[handoff]
    heading = float(np.asarray(ego_state["heading"], dtype=float)[handoff])
    R = args.radius

    def keep(xy: np.ndarray) -> bool:
        return bool(np.any(np.abs(xy[:, 0]) < R * 1.3) and np.any(np.abs(xy[:, 1]) < R * 1.3))

    lanes, centres, crosswalks = [], [], []
    for _fid, feat in (sd.get("map_features") or {}).items():
        ftype = str(feat.get("type", ""))
        poly, line = feat.get("polygon"), feat.get("polyline")
        is_lane = MetaDriveType.is_lane(ftype)
        # Lane SURFACES carry the drivable area; their centrelines carry the
        # direction of travel. Both are worth drawing and they read differently,
        # so they ship separately rather than as one undifferentiated soup.
        if poly is not None and len(poly) >= 3 and is_lane:
            xy = to_base(np.asarray(poly, dtype=float), origin, heading)
            if keep(xy):
                lanes.append(np.round(simplify(xy, args.tol * 2), 2).tolist())
        if line is not None and len(line) >= 2:
            xy = to_base(np.asarray(line, dtype=float), origin, heading)
            if not keep(xy):
                continue
            s = np.round(simplify(xy, args.tol), 2).tolist()
            if is_lane:
                centres.append(s)
            elif "CROSSWALK" in ftype.upper():
                crosswalks.append(s)

    # Other actors at the hand-off frame: boxes, so the reader can see what the
    # displaced ego was next to. Types are kept because a pedestrian and a bus
    # are not the same obstacle.
    actors = []
    for tid, track in (sd.get("tracks") or {}).items():
        if tid == sdc:
            continue
        st = track.get("state", {}) or {}
        pos = np.asarray(st.get("position", []), dtype=float)
        if pos.ndim != 2 or handoff >= len(pos):
            continue
        if not bool(np.asarray(st.get("valid", np.ones(len(pos))), dtype=bool)[handoff]):
            continue
        xy = to_base(pos[handoff:handoff + 1], origin, heading)[0]
        if abs(xy[0]) > R or abs(xy[1]) > R:
            continue
        hd = np.asarray(st.get("heading", np.zeros(len(pos))), dtype=float)
        length, width = track_dims(track, handoff, fallback=(4.5, 1.8))
        actors.append({
            "t": str(track.get("type", "")),
            "xy": [round(float(xy[0]), 2), round(float(xy[1]), 2)],
            # heading relative to the baseline ego, so the page never needs the
            # world frame at all
            "h": round(float(hd[handoff]) - heading, 4),
            "l": round(float(length), 2), "w": round(float(width), 2),
        })

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    payload = {
        "token": args.token, "scene": scene, "handoff": handoff, "radius_m": R,
        "frame": "baseline ego at hand-off; [lateral(+left), forward] metres",
        # The world-frame origin and heading, so a caller can put the run's own
        # `selected_world` trajectories into this frame without reloading the
        # scenario.
        "origin_world": [round(float(v), 3) for v in origin[:2]],
        "heading_world": round(heading, 6),
        "lanes": lanes, "lane_centres": centres, "crosswalks": crosswalks,
        "actors": actors,
        "ego_box": [4.515, 2.0],
    }
    p = out / f"{args.token}.bev.json"
    p.write_text(json.dumps(payload, separators=(",", ":")))
    print(f"{args.token}: {len(lanes)} lane polys, {len(centres)} centrelines, "
          f"{len(crosswalks)} crosswalks, {len(actors)} actors, "
          f"{p.stat().st_size/1e3:.0f} kB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
