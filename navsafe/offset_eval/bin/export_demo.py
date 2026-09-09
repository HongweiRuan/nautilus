#!/usr/bin/env python3
"""Pack one scenario's cells into the JSON the demo page loads.

The page's question is "move the ego on the hand-off frame and watch what it
plans instead", so for each (offset arm, model) it needs three things, and the
run already writes all three into ``plan_records.json``:

    every trajectory the policy considered   predictions[i].candidates_ego + candidate_scores
    the one it chose                         predictions[i].selected_ego / selected_world
    the one it actually drove                executed

By default only the prediction AT the hand-off is kept -- that is the frame the
slider moves, and keeping all 39 replans per cell would multiply the payload by
forty for data the page never draws. ``--all-predictions`` keeps them, for a
page that wants to scrub through the episode.

Runs ON THE CLUSTER: the run directory is on CephFS.

    kubectl exec -n cogrob <pod> -- python3 /path/export_demo.py <token> <out_dir>
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from pathlib import Path

RUN = Path("/avl-west/runs/20260905-handoff-perturb-demo/eval/seed0")

# The models this campaign is about, in the order the page shows them. An
# explicit list rather than "whatever directories exist": the run also holds
# `resworld`, a world-model row that was replaced by simwam partway through and
# whose ~216 orphan cells would otherwise be exported as a tenth model with
# holes all through it.
MODELS = [
    "pdm_closed",                    # rule-based (privileged)
    "diffusiondrive",                # IL                      -- pairs with
    "diffusiondrive_beyonddrive",    # augmentation            -- the row above
    "recogdrive_il",                 # IL stage                -- pairs with
    "recogdrive_rl",                 # after RL fine-tuning    -- the row above
    "simwam_base",                   # world-model, before RL  -- pairs with
    "simwam",                        # SimWAM-RL               -- the row above
    "mtdrive_sft",                   # SFT stage               -- pairs with
    "mtdrive_mtgrpo",                # after mtGRPO            -- the row above
]

# How the page names each row. Kept beside the model list rather than in the
# page's JavaScript, so a model added here cannot show up in the UI as a bare
# directory name.
MODEL_LABELS = {
    "pdm_closed": "PDM-Closed (rule-based)",
    "diffusiondrive": "DiffusionDrive (IL)",
    "diffusiondrive_beyonddrive": "DiffusionDrive + BeyondDrive (aug)",
    "recogdrive_il": "ReCogDrive-IL (before RL)",
    "recogdrive_rl": "ReCogDrive-RL (RLFT)",
    "simwam_base": "SimWAM (before RL)",
    "simwam": "SimWAM-RL (world-model)",
    "mtdrive_sft": "MTDrive-SFT (before RL)",
    "mtdrive_mtgrpo": "MTDrive-mtGRPO (RLFT)",
}

# Which rows are a before/after-training pair, for the page's paired view: one
# BEV, two policies, one slider moving both. DiffusionDrive/BeyondDrive is an
# augmentation pair rather than an RL stage, which is why it is labelled apart.
PAIRS = [
    {"before": "recogdrive_il",  "after": "recogdrive_rl",    "kind": "RL fine-tuning"},
    {"before": "simwam_base",    "after": "simwam",           "kind": "FlowGRPO"},
    {"before": "mtdrive_sft",    "after": "mtdrive_mtgrpo",   "kind": "mtGRPO"},
    {"before": "diffusiondrive", "after": "diffusiondrive_beyonddrive",
     "kind": "augmentation training"},
]

# The slider's three axes, in the order the page shows them. The values are the
# metres / degrees each arm applied, so the page can label ticks without parsing
# the arm names.
AXES = {
    "lateral": (["latm1.5", "latm1.0", "latm0.5", "base", "latp0.5", "latp1.0", "latp1.5"],
                [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]),
    "longitudinal": (["lonm1.5", "lonm1.0", "lonm0.5", "base", "lonp0.5", "lonp1.0", "lonp1.5"],
                     [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]),
    "yaw": (["yawm45.0", "yawm30.0", "yawm15.0", "base", "yawp15.0", "yawp30.0", "yawp45.0"],
            [-45.0, -30.0, -15.0, 0.0, 15.0, 30.0, 45.0]),
}


def r(x, n=3):
    """Round for the wire. Sub-millimetre precision on a 700 px canvas is bytes
    for nothing, and these payloads are mostly coordinates."""
    if isinstance(x, list):
        return [r(v, n) for v in x]
    if isinstance(x, float):
        return None if math.isnan(x) else round(x, n)
    return x


def handoff_prediction(preds: list, handoff: int) -> dict | None:
    """The first replan the policy made once it was driving.

    Not simply ``frame == handoff``: the policy replans every ``replan_rate``
    frames, so the hand-off frame itself usually has no record of its own. The
    first post-warm-up prediction is the one the perturbation acted on.
    """
    after = [p for p in preds if not p.get("is_warmup") and p.get("frame", -1) >= handoff]
    return after[0] if after else (preds[-1] if preds else None)


def pack_cell(cell: Path, keep_all: bool) -> dict | None:
    pr = cell / "plan_records.json"
    nm = cell / "navsafe_metrics.json"
    if not pr.is_file() or not nm.is_file():
        return None                      # not finished, or failed -- skip
    p = json.loads(pr.read_text())
    m = json.loads(nm.read_text())

    preds = p.get("predictions") or []
    handoff = int(p.get("handoff_frame", 20))
    chosen = preds if keep_all else [x for x in (handoff_prediction(preds, handoff),) if x]

    out_preds = []
    for x in chosen:
        out_preds.append({
            "frame": x.get("frame"), "t_s": r(x.get("t_s"), 2),
            "ego_position": r(x.get("ego_position")),
            "ego_heading": r(x.get("ego_heading"), 4),
            # A candidate set is what a trajectory-distribution plot is made of.
            # Models that emit a single trajectory leave these null rather than
            # absent, so the page can tell "one trajectory" from "not recorded".
            "candidates_ego": r(x.get("candidates_ego"), 2),
            "candidate_scores": r(x.get("candidate_scores"), 4),
            "selected_index": x.get("selected_index"),
            "selected_ego": r(x.get("selected_ego"), 2),
            "selected_world": r(x.get("selected_world"), 2),
            "selected_speeds_mps": r(x.get("selected_speeds_mps"), 2),
            "emergency_brake": x.get("emergency_brake"),
        })

    # The whole driven path, one entry per sim step. This is what makes the
    # before/after comparison legible: the plan says what it intended, the
    # executed path says what the closed loop actually did with it.
    ex = [{"frame": e.get("frame"), "xy": r(e.get("position", [0, 0, 0])[:2], 2),
           "h": r(e.get("heading"), 4)} for e in (p.get("executed") or [])]

    # navsafe_metrics.json nests: `metrics` holds the four headline numbers,
    # `termination` is its own object, and the EPDMS channel breakdown lives
    # under `driving_score_breakdown`. Reading them off the top level silently
    # yields None for everything, which is how an earlier version of this
    # shipped a payload whose termination captions were all blank.
    res = m.get("metrics") or {}
    term = m.get("termination") or {}
    brk = m.get("driving_score_breakdown") or {}
    frames = m.get("frames") or {}
    # The hand-off prediction, flattened to the names the page reads. The page
    # puts a plan in the baseline ego's frame with toWorld(selected_ego, ego_xy,
    # ego_heading), so those three have to travel together and mean the same
    # thing they did when the run wrote them.
    h = out_preds[0] if out_preds else {}
    ego = h.get("ego_position") or [None, None, None]
    # Where in `executed` the warm-up ends. Everything before it is identical in
    # every arm -- the same logged replay -- so the page draws it once, faintly,
    # instead of seven times.
    hidx = next((i for i, e in enumerate(ex) if (e.get("frame") or 0) >= handoff), 0)

    return {
        "status": m.get("status"),
        "handoff_idx": hidx,
        "ego_xy": r(ego[:2], 3),
        "ego_heading": h.get("ego_heading"),
        "selected_ego": h.get("selected_ego"),
        "selected_index": h.get("selected_index"),
        "candidates": h.get("candidates_ego"),
        "scores": h.get("candidate_scores"),
        # null, not absent: a model that emits ONE trajectory is a different
        # thing from a model whose candidates were not recorded, and the page
        # says so rather than drawing an empty fan.
        "has_candidates": bool(h.get("candidates_ego")),
        "executed_xy": [e["xy"] for e in ex],
        "executed_frames": len(ex),
        "driving_score": r(res.get("driving_score"), 3),
        "success": res.get("success"),
        "collided": bool(term.get("collision_count") or 0),
        "termination": term.get("reason"),
        "termination_detail": term.get("detail"),
        # Whether the ending was the POLICY's doing. A run cut short by the
        # harness, or one where another vehicle hit a stationary ego, is not the
        # same finding as one the policy drove into, and the page should not
        # read them the same way.
        "policy_attributed": term.get("policy_attributed"),
        "comfort": r(res.get("comfort"), 3),
        "efficiency_pct": r(res.get("efficiency_pct"), 2),
        # Kept beyond what the page reads today: every replan when
        # --all-predictions is on, the speeds, and the full EPDMS breakdown.
        "predictions": out_preds if keep_all else None,
        "route_completion_pct": r(brk.get("route_completion_pct"), 2),
        "penalty": r(brk.get("penalty"), 4),
        "frames_scored": frames.get("scored"),
        # Which penalty channels actually fired, so a low score can be read
        # rather than just seen. A LIST of {channel, coefficient, count, factor,
        # source}, not a mapping -- only the channels that bit are worth
        # shipping, and `factor` 1.0 means it did not.
        "channels": [{"channel": c.get("channel"), "count": c.get("count"),
                      "factor": r(c.get("factor"), 3)}
                     for c in (brk.get("channels") or [])
                     if (c.get("factor") is not None and c.get("factor") != 1.0)
                     or (c.get("count") or 0)],
    }


def camera_rig() -> dict:
    """The navsim rig, straight out of the code the eval rendered with.

    Shipped with the payload so the page can project a trajectory into a plate
    itself. The evaluator only annotates CAM_F0, so the surround views would
    otherwise be bare pictures with no way to draw a plan on them.
    """
    try:
        from nexussim.utils.camera_utils import NAVSIM_CAM_CONFIGS
    except Exception as exc:                                       # noqa: BLE001
        print(f"  camera rig unavailable ({exc}); page will fall back to CAM_F0 only")
        return {}
    keep = ("x", "y", "z", "yaw", "pitch", "roll",
            "fov", "fov_h", "fov_v", "width", "height")
    return {cam: {k: float(cfg[k]) for k in keep if k in cfg}
            for cam, cfg in NAVSIM_CAM_CONFIGS.items()
            if cam in ("CAM_F0", "CAM_L0", "CAM_R0", "CAM_B0")}


def copy_images(cell: Path, handoff: int, dest: Path, arm: str, model: str) -> dict:
    """Copy the hand-off frame's plates out of the run into the payload's img/.

    ``frames/`` is one directory per SIM STEP, zero-padded, holding the four
    camera jpgs and the evaluator's topdown. The hand-off frame is the one the
    slider moves, so that is the only step worth copying -- the rest is 100+
    steps x 5 images x every cell.
    """
    src = cell / "frames" / f"{handoff:05d}"
    if not src.is_dir():
        # A cell whose episode ended before the hand-off has no such frame.
        cand = sorted((cell / "frames").glob("*")) if (cell / "frames").is_dir() else []
        if not cand:
            return {}
        src = cand[-1]
    dest.mkdir(parents=True, exist_ok=True)
    out = {}
    for fname, key in (("cam_f0.jpg", "CAM_F0"), ("cam_l0.jpg", "CAM_L0"),
                       ("cam_r0.jpg", "CAM_R0"), ("cam_b0.jpg", "CAM_B0"),
                       ("topdown.png", "topdown")):
        f = src / fname
        if not f.is_file():
            continue
        rel = f"img/{cell.parent.parent.name}/{arm}__{model}__{key}.jpg"
        if not _shrink(f, dest.parent.parent / rel):
            continue
        out[key] = rel
    return out


def _shrink(src: Path, dst: Path, width: int = 960, quality: int = 72) -> bool:
    """Downscale into the payload.

    The renderer writes 1920x1120, about 350 kB a plate, and the page shows them
    a few hundred pixels wide. Five scenarios x 19 arms x 9 models x 5 plates is
    4185 of them: 1.2 GB at full size, and this is a GitHub Pages repo. Halving
    the width and re-encoding at 72 costs nothing visible at the size they are
    displayed.

    Falls back to a straight copy when Pillow is not importable, because a demo
    with big images beats a demo with none.
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        from PIL import Image
    except ImportError:
        shutil.copyfile(src, dst)
        return True
    try:
        with Image.open(src) as im:
            im = im.convert("RGB")
            if im.width > width:
                im = im.resize((width, round(im.height * width / im.width)),
                               Image.LANCZOS)
            im.save(dst, "JPEG", quality=quality, optimize=True)
        return True
    except Exception as exc:                                       # noqa: BLE001
        print(f"  shrink failed for {src.name}: {exc}")
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("token")
    ap.add_argument("out_dir")
    ap.add_argument("--all-predictions", action="store_true",
                    help="keep every replan, not just the one at the hand-off")
    ap.add_argument("--images", action="store_true",
                    help="also copy the hand-off frame's four camera plates and "
                         "the evaluator's topdown into <out_dir>/img/<token>/")
    args = ap.parse_args()

    hits = sorted(RUN.glob(f"*/{args.token}"))
    if not hits:
        print(f"{args.token}: not in {RUN}")
        return 1
    scen = hits[0]
    leaf = scen.parent.name

    img_root = Path(args.out_dir) / "img" / args.token
    cells, skipped, n_img = {}, 0, 0
    for arm in sorted(d for d in scen.iterdir() if d.is_dir()):
        for name in MODELS:
            cell = arm / name
            if not cell.is_dir():
                continue
            packed = pack_cell(cell, args.all_predictions)
            if packed is None:
                skipped += 1
                continue
            if arm.name not in cells:
                rec = json.loads((cell / "plan_records.json").read_text())
                cells[arm.name] = {
                    "handoff_frame": int(rec.get("handoff_frame", 20)),
                    "perturbation": rec.get("perturbation_requested"),
                    "models": {},
                }
            if args.images:
                # The hand-off lives on the ARM now, not in the packed model:
                # every model in an arm hands over on the same frame, because it
                # is a property of the scenario and the recipe, not the policy.
                im = copy_images(
                    cell, cells[arm.name]["handoff_frame"], img_root, arm.name, name)
                n_img += len(im)
                # The page reads three separate fields, not one map: the front
                # plate is the one it annotates, the topdown is the evaluator's
                # own BEV, and the other three are the surround strip.
                packed["cam"] = im.get("CAM_F0")
                packed["bev"] = im.get("topdown")
                packed["surround"] = {k: v for k, v in im.items()
                                      if k in ("CAM_L0", "CAM_R0", "CAM_B0")}
            cells[arm.name]["models"][name] = packed

    models = [m for m in MODELS if any(m in a["models"] for a in cells.values())]
    pairs = [p for p in PAIRS if p["before"] in models and p["after"] in models]
    payload = {
        "token": args.token, "leaf": leaf,
        "axes": {k: {"arms": a, "values": v} for k, (a, v) in AXES.items()},
        "models": models,
        "model_labels": {m: MODEL_LABELS.get(m, m) for m in models},
        "pairs": pairs,
        # The rig, so the page can project a trajectory into any of the four
        # plates itself instead of relying on the evaluator having drawn it.
        "cameras": camera_rig(),
        "surround": ["CAM_L0", "CAM_R0", "CAM_B0"],
        "arms": cells,
    }
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    f = out / f"{args.token}.demo.json"
    f.write_text(json.dumps(payload, separators=(",", ":")))
    n = sum(len(a["models"]) for a in cells.values())
    print(f"{args.token} ({leaf}): {n} cells over {len(cells)} arms x {len(models)} models"
          f"{f', {skipped} unfinished skipped' if skipped else ''}"
          f"{f', {n_img} images' if n_img else ''}"
          f" -> {f} ({f.stat().st_size/1e6:.1f} MB)")
    for m in models:
        have = sum(1 for a in cells.values() if m in a["models"])
        print(f"    {m:<28} {have}/{len(cells)} arms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
