#!/usr/bin/env python3
"""
Visualize trajectory proposals with scores from 3 scorers on unified BEV & RGB.

For each frame, generates a single BEV and single RGB image showing:
  - All proposals with the average score color-coding
  - Each scorer's selected trajectory in a distinct color
  - Top proposals labeled with all 3 scores (L/G/I)
  - Discrepancy highlights when scorers disagree

Usage:
    python scripts/vis_proposals_scored.py \
        --model-type diffusiondrivev2 \
        --scenario-path /avl-west/navsim/navhard_md_logs/sd_49074bfb7c9e5c26 \
        --output-dir ./vis_proposals_output \
        --eval-frames 40
"""

import argparse
import os
import sys
from pathlib import Path

# Add paths
REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
sys.path.insert(0, str(REPO_ROOT / 'nuplan-devkit'))
os.chdir(str(REPO_ROOT / 'bridgesim' / 'evaluation'))

import cv2
import numpy as np
import torch
from tqdm import tqdm

from bridgesim.evaluation.core.base_evaluator import BaseEvaluator
from bridgesim.evaluation.core.environment_manager import EnvironmentManager
from bridgesim.evaluation.utils.controller_md import PurePursuitController
from bridgesim.evaluation.models.base_adapter import BaseModelAdapter
from bridgesim.evaluation.scorers import (
    CoarseTopKScorer,
    EPDMSTrajectoryScorer_Fast,
    EPDMSEgoScorer,
)
from metadrive.policy.env_input_policy import EnvInputPolicy

# Import camera projection from sibling script
sys.path.insert(0, str(REPO_ROOT / 'scripts'))
from vis_trajectory_on_cam import project_ego_waypoints_to_camera


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Distinct colors (BGR) for each scorer's selected trajectory
SCORER_COLORS = {
    "coarse_topk": (255, 255, 0),   # Cyan  - Learned
    "epdms_fast":  (0, 0, 255),     # Red   - GT
    "epdms_ego":   (0, 255, 0),     # Green - Intrinsic
}
SCORER_LABELS = {
    "coarse_topk": "L",   # Learned
    "epdms_fast":  "G",   # GT
    "epdms_ego":   "I",   # Intrinsic
}
SCORER_DISPLAY = {
    "coarse_topk": "Learned (coarse_topk)",
    "epdms_fast":  "GT (epdms_fast)",
    "epdms_ego":   "Intrinsic (epdms_ego)",
}


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------

def smooth_points(points, num_interp=50):
    """Cubic-spline interpolate a polyline for smooth curves.

    Args:
        points: list of (x, y) tuples (at least 2)
        num_interp: number of output points
    Returns:
        np.ndarray of shape (num_interp, 2), dtype int32
    """
    pts = np.array(points, dtype=np.float64)
    if len(pts) < 2:
        return pts.astype(np.int32)
    if len(pts) == 2:
        # Linear interp for 2 points
        t = np.linspace(0, 1, num_interp)
        out = pts[0] + np.outer(t, pts[1] - pts[0])
        return out.astype(np.int32)

    from scipy.interpolate import CubicSpline
    t_orig = np.linspace(0, 1, len(pts))
    t_fine = np.linspace(0, 1, num_interp)
    cs_x = CubicSpline(t_orig, pts[:, 0])
    cs_y = CubicSpline(t_orig, pts[:, 1])
    out = np.column_stack([cs_x(t_fine), cs_y(t_fine)])
    return out.astype(np.int32)


def score_to_color(score_norm):
    """Map normalized score [0,1] to BGR color: blue(low) -> green(mid) -> red(high)."""
    if score_norm < 0.5:
        t = score_norm * 2  # 0..1
        return (int(255 * (1 - t)), int(255 * t), 0)  # blue -> green
    else:
        t = (score_norm - 0.5) * 2  # 0..1
        return (0, int(255 * (1 - t)), int(255 * t))  # green -> red


def normalize_scores(scores):
    """Normalize scores to [0,1] with min/max."""
    smin, smax = scores.min(), scores.max()
    if smax - smin > 1e-8:
        return (scores - smin) / (smax - smin)
    return np.ones_like(scores) * 0.5


def pick_label_indices(all_scores_dict, n_top=5):
    """Pick indices worth labeling: union of top-K from each scorer + any scorer's best."""
    label_set = set()
    for scorer_name, scores in all_scores_dict.items():
        order = np.argsort(scores)[::-1]
        label_set.update(order[:n_top].tolist())
        label_set.add(order[0])  # always include each scorer's best
    return sorted(label_set)


def draw_smooth_line(img, points, color, thickness, alpha=1.0):
    """Draw a smooth anti-aliased polyline through waypoints.

    Args:
        img: image to draw on (modified in-place unless alpha < 1)
        points: list of (x, y) int tuples
        color: BGR tuple
        thickness: line thickness
        alpha: opacity [0,1]. 1.0 = fully opaque (fast path)
    """
    if len(points) < 2:
        return
    smooth = smooth_points(points, num_interp=60)
    if alpha < 1.0:
        overlay = img.copy()
        cv2.polylines(overlay, [smooth], False, color, thickness, cv2.LINE_AA)
        cv2.addWeighted(overlay, alpha, img, 1 - alpha, 0, img)
    else:
        cv2.polylines(img, [smooth], False, color, thickness, cv2.LINE_AA)


# ---------------------------------------------------------------------------
# Unified BEV Drawing (all 3 scorers on one image)
# ---------------------------------------------------------------------------

def draw_proposals_bev_unified(topdown_frame, proposals_ego, all_scores,
                               all_best_idx, frame_id, model_type,
                               ego_position, pred_heading,
                               screen_size=800, bev_scaling=None):
    """
    Draw all proposals on one BEV image with multi-scorer labels and
    each scorer's selected trajectory highlighted in its color.

    Args:
        topdown_frame: (H, W, 3) BEV image from MetaDrive
        proposals_ego: (N, 8, 2) proposals in ego frame [lateral, forward]
        all_scores: dict {scorer_name: (N,) scores}
        all_best_idx: dict {scorer_name: int best index}
        frame_id: int
        model_type: str
        ego_position: (2,) current ego position
        pred_heading: float heading
        screen_size: int pixel size
        bev_scaling: float pixels per meter
    """
    img = topdown_frame.copy()
    scaling = bev_scaling if bev_scaling is not None else (screen_size / 20.0)
    center_px = screen_size // 2
    font = cv2.FONT_HERSHEY_SIMPLEX

    cos_h = np.cos(pred_heading)
    sin_h = np.sin(pred_heading)

    def ego_to_pixel(wp):
        world_x = ego_position[0] + cos_h * wp[1] - sin_h * wp[0]
        world_y = ego_position[1] + sin_h * wp[1] + cos_h * wp[0]
        dx_px = (world_x - ego_position[0]) * scaling
        dy_px = (world_y - ego_position[1]) * scaling
        return int(center_px + dx_px), int(center_px - dy_px)

    def in_bounds(px, py):
        return 0 <= px < screen_size and 0 <= py < screen_size

    N = len(proposals_ego)

    # Compute average normalized score for base coloring
    avg_scores = np.zeros(N)
    for sc in all_scores.values():
        avg_scores += normalize_scores(sc)
    avg_scores /= len(all_scores)

    # Indices to label with multi-score text
    label_indices = pick_label_indices(all_scores, n_top=5)
    label_set = set(label_indices)
    best_set = set(all_best_idx.values())

    # Only show top ~40% proposals to reduce visual clutter, sorted by avg score
    show_cutoff = max(int(N * 0.4), len(label_set | best_set))
    show_order = np.argsort(avg_scores)[::-1]
    show_set = set(show_order[:show_cutoff].tolist()) | label_set | best_set

    # --- Pass 1: Draw background proposals as smooth semi-transparent lines ---
    for i in show_order[:show_cutoff]:
        if i in best_set or i in label_set:
            continue  # draw these in later passes
        color = score_to_color(avg_scores[i])
        points = []
        for wp in proposals_ego[i]:
            px, py = ego_to_pixel(wp)
            if in_bounds(px, py):
                points.append((px, py))
        if len(points) >= 2:
            draw_smooth_line(img, points, color, 2, alpha=0.35)

    # --- Pass 2: Draw labeled proposals with thicker lines + multi-score labels ---
    for i in label_indices:
        if i in best_set:
            continue  # draw selected ones in pass 3
        color = score_to_color(avg_scores[i])
        points = []
        for wp in proposals_ego[i]:
            px, py = ego_to_pixel(wp)
            if in_bounds(px, py):
                points.append((px, py))
        if len(points) >= 2:
            draw_smooth_line(img, points, color, 3)
            _draw_multi_score_label(img, points[-1], i, all_scores, font, screen_size)

    # --- Pass 3: Draw each scorer's selected trajectory in its color ---
    for scorer_name, best_i in all_best_idx.items():
        sc_color = SCORER_COLORS[scorer_name]
        points = []
        for wp in proposals_ego[best_i]:
            px, py = ego_to_pixel(wp)
            if in_bounds(px, py):
                points.append((px, py))
        if len(points) >= 2:
            # Dark outline for contrast
            draw_smooth_line(img, points, (0, 0, 0), 5)
            draw_smooth_line(img, points, sc_color, 3)
            # Draw dots at waypoints
            for pt in points:
                cv2.circle(img, pt, 4, sc_color, -1, cv2.LINE_AA)
                cv2.circle(img, pt, 4, (0, 0, 0), 1, cv2.LINE_AA)
            # Score label
            _draw_multi_score_label(img, points[-1], best_i, all_scores, font,
                                    screen_size, highlight=scorer_name)

    # --- Ego marker ---
    cv2.circle(img, (center_px, center_px), 6, (255, 255, 255), -1)
    cv2.circle(img, (center_px, center_px), 6, (0, 0, 0), 2)

    # --- Discrepancy indicator ---
    unique_best = len(set(all_best_idx.values()))
    if unique_best > 1:
        disc_text = f"DISCREPANCY: {unique_best} different selections"
        disc_color = (0, 0, 255)  # red
    else:
        disc_text = "All scorers agree"
        disc_color = (0, 255, 0)  # green

    # --- Legend ---
    legend_h = 130
    overlay = img.copy()
    cv2.rectangle(overlay, (5, 5), (320, 5 + legend_h), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.7, img, 0.3, 0, img)

    y = 22
    cv2.putText(img, f"Frame: {frame_id}  |  {model_type}", (10, y), font, 0.5, (255, 255, 255), 1)
    y += 18
    cv2.putText(img, f"Proposals: {N}", (10, y), font, 0.4, (200, 200, 200), 1)
    y += 16

    for scorer_name in ["coarse_topk", "epdms_fast", "epdms_ego"]:
        sc_color = SCORER_COLORS[scorer_name]
        best_i = all_best_idx[scorer_name]
        sc_val = all_scores[scorer_name][best_i]
        label = f"{SCORER_DISPLAY[scorer_name]}: best={sc_val:.3f} (#{best_i})"
        # Color swatch
        cv2.rectangle(img, (10, y - 10), (22, y), sc_color, -1)
        cv2.putText(img, label, (26, y - 1), font, 0.35, (255, 255, 255), 1)
        y += 16

    cv2.putText(img, disc_text, (10, y + 2), font, 0.4, disc_color, 1)

    return img


def _draw_multi_score_label(img, endpoint, idx, all_scores, font,
                            screen_size, highlight=None):
    """Draw a compact label showing L/G/I scores at a trajectory endpoint."""
    # Build label: "L:.82 G:.45 I:.71"
    parts = []
    for sn in ["coarse_topk", "epdms_fast", "epdms_ego"]:
        val = all_scores[sn][idx]
        parts.append(f"{SCORER_LABELS[sn]}:{val:.2f}")
    label = " ".join(parts)

    ex, ey = endpoint
    font_scale = 0.32
    thickness = 1
    (tw, th), _ = cv2.getTextSize(label, font, font_scale, thickness)

    # Position label, keeping it in bounds
    lx = min(max(ex + 4, 2), screen_size - tw - 4)
    ly = min(max(ey - 4, th + 4), screen_size - 4)

    # Background
    bg_color = (0, 0, 0)
    if highlight:
        bg_color = tuple(c // 3 for c in SCORER_COLORS[highlight])
    cv2.rectangle(img, (lx - 1, ly - th - 2), (lx + tw + 2, ly + 3), bg_color, -1)
    if highlight:
        cv2.rectangle(img, (lx - 1, ly - th - 2), (lx + tw + 2, ly + 3),
                      SCORER_COLORS[highlight], 1)
    cv2.putText(img, label, (lx, ly), font, font_scale, (255, 255, 255), thickness)


# ---------------------------------------------------------------------------
# Unified RGB Drawing (all 3 scorers on one image)
# ---------------------------------------------------------------------------

def draw_proposals_rgb_unified(cam_img, proposals_ego, all_scores,
                               all_best_idx, frame_id, model_type,
                               cam_config, n_show=5):
    """
    Draw each scorer's selected trajectory on one camera image in distinct colors.

    Args:
        cam_img: (H, W, 3) front camera image
        proposals_ego: (N, 8, 2) in ego frame [lateral, forward]
        all_scores: dict {scorer_name: (N,) scores}
        all_best_idx: dict {scorer_name: int}
        frame_id: int
        model_type: str
        cam_config: dict with camera params
        n_show: top-N from each scorer to draw as thin lines
    """
    img = cam_img.copy()
    H, W = img.shape[:2]
    font = cv2.FONT_HERSHEY_SIMPLEX

    # Gather unique top-N indices across all scorers (for thin background lines)
    bg_indices = set()
    for scores in all_scores.values():
        order = np.argsort(scores)[::-1]
        bg_indices.update(order[:n_show].tolist())
    best_set = set(all_best_idx.values())
    bg_indices -= best_set  # don't draw best ones as background

    # Compute avg normalized scores for coloring background lines
    N = len(proposals_ego)
    avg_scores = np.zeros(N)
    for sc in all_scores.values():
        avg_scores += normalize_scores(sc)
    avg_scores /= len(all_scores)

    # --- Background: draw top proposals as smooth semi-transparent lines ---
    for i in bg_indices:
        traj = proposals_ego[i]
        pixels, valid = project_ego_waypoints_to_camera(traj, cam_config, img.shape)
        color = score_to_color(avg_scores[i])
        valid_pixels = [(int(pixels[k][0]), int(pixels[k][1]))
                        for k in range(len(pixels))
                        if valid[k] and 0 <= int(pixels[k][0]) < W and 0 <= int(pixels[k][1]) < H]
        if len(valid_pixels) >= 2:
            draw_smooth_line(img, valid_pixels, color, 2, alpha=0.35)

    # --- Each scorer's selected trajectory ---
    label_y_offset = 0
    for scorer_name in ["coarse_topk", "epdms_fast", "epdms_ego"]:
        best_i = all_best_idx[scorer_name]
        sc_color = SCORER_COLORS[scorer_name]
        traj = proposals_ego[best_i]
        pixels, valid = project_ego_waypoints_to_camera(traj, cam_config, img.shape)

        valid_pixels = [(int(pixels[k][0]), int(pixels[k][1]))
                        for k in range(len(pixels))
                        if valid[k] and 0 <= int(pixels[k][0]) < W and 0 <= int(pixels[k][1]) < H]
        if len(valid_pixels) >= 2:
            # Dark outline + colored smooth line
            draw_smooth_line(img, valid_pixels, (0, 0, 0), 6)
            draw_smooth_line(img, valid_pixels, sc_color, 4)
            for pt in valid_pixels:
                cv2.circle(img, pt, 4, sc_color, -1, cv2.LINE_AA)
                cv2.circle(img, pt, 4, (0, 0, 0), 1, cv2.LINE_AA)

            # Label at endpoint
            ep = valid_pixels[-1]
            sc_val = all_scores[scorer_name][best_i]
            label = f"{SCORER_LABELS[scorer_name]}:{sc_val:.3f} (#{best_i})"
            (tw, th), _ = cv2.getTextSize(label, font, 0.55, 1)
            lx = min(max(ep[0] + 10, 5), W - tw - 5)
            ly = min(max(ep[1] - 8 + label_y_offset, th + 5), H - 5)
            cv2.rectangle(img, (lx - 3, ly - th - 4), (lx + tw + 4, ly + 5), (0, 0, 0), -1)
            cv2.rectangle(img, (lx - 3, ly - th - 4), (lx + tw + 4, ly + 5), sc_color, 2)
            cv2.putText(img, label, (lx, ly), font, 0.55, sc_color, 1, cv2.LINE_AA)
            label_y_offset += 28

    # --- HUD ---
    hud_h = 55
    overlay = img.copy()
    cv2.rectangle(overlay, (0, 0), (W, hud_h), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.6, img, 0.4, 0, img)
    cv2.putText(img, f"Frame {frame_id}  |  {model_type}", (10, 20), font, 0.55, (255, 255, 255), 1)

    # Scorer legend in HUD
    x_off = 10
    for scorer_name in ["coarse_topk", "epdms_fast", "epdms_ego"]:
        sc_color = SCORER_COLORS[scorer_name]
        disp = SCORER_DISPLAY[scorer_name]
        cv2.rectangle(img, (x_off, 30), (x_off + 12, 42), sc_color, -1)
        cv2.putText(img, disp, (x_off + 16, 42), font, 0.4, (255, 255, 255), 1)
        x_off += 16 + len(disp) * 8 + 15

    # Discrepancy
    unique_best = len(set(all_best_idx.values()))
    if unique_best > 1:
        cv2.putText(img, f"DISCREPANCY ({unique_best} selections)",
                    (W - 300, 20), font, 0.5, (0, 0, 255), 1, cv2.LINE_AA)

    return img


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def create_model_adapter(model_type, ckpt, plan_anchor_path, v2_ckpt):
    """Create model adapter with all 3 scorers attached for multi-scoring."""
    if model_type == "diffusiondrivev2":
        from bridgesim.evaluation.models.diffusiondrivev2_adapter import DiffusionDriveV2Adapter
        # Use a dummy scorer to trigger forward_inference_scaling
        # We will score candidates ourselves with all 3 scorers
        dummy_scorer = EPDMSEgoScorer()
        adapter = DiffusionDriveV2Adapter(
            checkpoint_path=ckpt,
            plan_anchor_path=plan_anchor_path,
            scorer=dummy_scorer,
            num_groups=1,
        )
        return adapter

    elif model_type == "diffusiondrive":
        from bridgesim.evaluation.models.diffusiondrive_adapter import DiffusionDriveAdapter
        dummy_scorer = EPDMSEgoScorer()
        adapter = DiffusionDriveAdapter(
            checkpoint_path=ckpt,
            plan_anchor_path=plan_anchor_path,
            scorer=dummy_scorer,
            num_groups=1,
        )
        return adapter

    else:
        raise ValueError(f"Unsupported model type: {model_type}")


def run_visualization(args):
    """Main visualization loop."""

    model_type = args.model_type
    scenario_path = args.scenario_path
    output_base = Path(args.output_dir)

    # Paths
    ckpt = args.checkpoint
    plan_anchor = args.plan_anchor_path
    v2_ckpt = args.v2_checkpoint

    scenario_name = Path(scenario_path).name
    output_dir = output_base / model_type / scenario_name
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Model: {model_type}")
    print(f"Scenario: {scenario_name}")
    print(f"Output: {output_dir}")

    # --- Create model adapter ---
    adapter = create_model_adapter(model_type, ckpt, plan_anchor, v2_ckpt)

    # --- Create evaluator (reuse for env setup, perceive, ego state) ---
    evaluator = BaseEvaluator(
        model_adapter=adapter,
        scenario_path=scenario_path,
        output_dir=str(output_dir / "_eval_tmp"),
        traffic_mode="log_replay",
        enable_vis=True,
        save_perframe=False,
        eval_mode="closed_loop",
        controller_type="pure_pursuit",
        replan_rate=1,
        ego_replay_frames=0,
        eval_frames=args.eval_frames,
    )

    # --- Load model ---
    print("Loading model...")
    adapter.load_model()

    # --- Load scenario & env ---
    print("Loading scenario...")
    evaluator.load_scenario()
    evaluator.generate_route()
    evaluator.full_route = list(evaluator.route)

    evaluator.env_manager = EnvironmentManager(
        Path(scenario_path),
        traffic_mode="log_replay",
        render=True,
        image_on_cuda=False,
        agent_policy=EnvInputPolicy,
    )
    env = evaluator.env_manager.create_env()
    obs, info = env.reset(seed=0)

    evaluator.controller = PurePursuitController()

    # --- Initialize scorers ---
    print("Initializing scorers...")
    scorers = {}

    # 1. Learned scorer (coarse_topk)
    if model_type == "diffusiondrive":
        # DDv1 needs v2 checkpoint to load scorer modules
        scorers["coarse_topk"] = CoarseTopKScorer(
            v2_scorer_checkpoint_path=v2_ckpt,
            device="cuda",
        )
    else:
        # DDv2: coarse_scores come from model, scorer just picks argmax
        scorers["coarse_topk"] = CoarseTopKScorer(device="cuda")

    # 2. GT scorer (epdms_fast)
    scorers["epdms_fast"] = EPDMSTrajectoryScorer_Fast()
    scorers["epdms_fast"].initialize(evaluator.scenario_data, env)

    # 3. Intrinsic scorer (epdms_ego)
    scorers["epdms_ego"] = EPDMSEgoScorer()
    scorers["epdms_ego"].initialize(evaluator.scenario_data, env)

    # Initialize adapter's dummy scorer too (so it can do ego->world transform)
    adapter.scorer.initialize(evaluator.scenario_data, env)

    # --- Camera config ---
    cam_configs = adapter.get_camera_configs()
    cam_cfg = cam_configs.get('CAM_F0', None)

    # --- Get BEV scaling ---
    # We need the MetaDrive top_down_renderer scaling for accurate BEV drawing
    bev_scaling = None

    # --- Main loop ---
    scenario_length = evaluator.scenario_data['length']
    num_frames = min(args.eval_frames, scenario_length) if args.eval_frames else scenario_length
    print(f"Processing {num_frames} frames...")

    prev_velocity = np.array([0.0, 0.0, 0.0])
    prev_heading = 0.0

    for frame_id in tqdm(range(num_frames), desc="Visualizing"):
        # --- Perceive ---
        imgs = evaluator.perceive(env, frame_id)

        # --- Ego state ---
        ego_state = evaluator.compute_ego_state(env, frame_id, prev_velocity, prev_heading)
        waypoint_pos, command, frame_idx_wp = evaluator.get_next_waypoint(ego_state['position'][:2])
        ego_state['waypoint'] = waypoint_pos
        ego_state['command'] = command

        # --- Model input ---
        model_input = adapter.prepare_input(
            images=imgs,
            ego_state=ego_state,
            scenario_data=evaluator.scenario_data,
            frame_id=frame_id,
        )

        # --- Inference (get all candidates) ---
        with torch.no_grad():
            model_output = adapter.model.forward_inference_scaling(
                model_input,
                num_groups=1,
                use_bev_calibrator=(adapter.bev_calibrator is not None),
            )

        # Get raw candidates
        all_candidates = model_output["all_candidates"]  # (B, N, 8, 3) tensor
        candidates_np = all_candidates[0].cpu().numpy()  # (N, 8, 3)
        N_cands = candidates_np.shape[0]

        # Swap columns: model [forward, lateral] -> evaluator [lateral, forward]
        proposals_ego = np.stack([
            np.column_stack([c[:, 1], c[:, 0]]) for c in candidates_np
        ])  # (N, 8, 2)

        # --- Score with all 3 scorers ---
        frame_scores = {}

        for scorer_name, scorer in scorers.items():
            result = scorer.select_best(
                model_output,
                ego_state=ego_state,
                frame_idx=frame_id,
            )
            all_scores = result["scores"][0].cpu().numpy() if torch.is_tensor(result["scores"]) else result["scores"]
            if len(all_scores.shape) > 1:
                all_scores = all_scores[0]
            frame_scores[scorer_name] = all_scores  # (N,)

        # --- Render BEV base (zoomed in: smaller film_size = tighter zoom) ---
        try:
            topdown_base = env.render(
                mode="top_down",
                semantic_map=True,
                film_size=(200, 200),
                screen_size=(800, 800),
                draw_target_vehicle_trajectory=True,
                window=False,
            )
            if bev_scaling is None:
                bev_scaling = env.engine.top_down_renderer.scaling
        except Exception as e:
            print(f"  Warning: BEV render failed at frame {frame_id}: {e}")
            topdown_base = np.zeros((800, 800, 3), dtype=np.uint8)
            if bev_scaling is None:
                bev_scaling = 40.0  # fallback

        # --- Get camera image ---
        frame_output = output_dir / "_eval_tmp" / scenario_name / f"{frame_id:05d}"
        cam_f0_path = frame_output / "cam_f0.jpg"
        cam_img = None
        if cam_f0_path.exists():
            cam_img = cv2.imread(str(cam_f0_path))

        # --- Draw unified images (all 3 scorers on one image) ---
        frame_out = output_dir / f"{frame_id:05d}"
        frame_out.mkdir(parents=True, exist_ok=True)

        # Collect best indices per scorer
        all_best_idx = {}
        for scorer_name in ["coarse_topk", "epdms_fast", "epdms_ego"]:
            all_best_idx[scorer_name] = int(np.argmax(frame_scores[scorer_name]))

        # BEV: unified image with all 3 scorers
        bev_img = draw_proposals_bev_unified(
            topdown_base, proposals_ego, frame_scores, all_best_idx,
            frame_id, model_type, ego_state['position'][:2],
            ego_state['heading'], screen_size=800, bev_scaling=bev_scaling,
        )
        cv2.imwrite(str(frame_out / "bev.png"), bev_img)

        # RGB: unified image with all 3 scorers
        if cam_img is not None and cam_cfg is not None:
            rgb_img = draw_proposals_rgb_unified(
                cam_img, proposals_ego, frame_scores, all_best_idx,
                frame_id, model_type, cam_cfg, n_show=5,
            )
            cv2.imwrite(str(frame_out / "rgb.png"), rgb_img)

        # --- Update state for next frame ---
        prev_velocity = ego_state.get('velocity', np.zeros(3))
        prev_heading = ego_state.get('heading', 0.0)

        # Step env with simple forward control (we don't care about closed-loop quality here)
        # Use the epdms_ego selected trajectory for control
        sel_traj_ego = proposals_ego[int(np.argmax(frame_scores["epdms_ego"]))]
        plan_subset = sel_traj_ego  # (8, 2)

        target_delta = ego_state['waypoint'] - ego_state['position'][:2]
        cos_neg = np.cos(-ego_state['heading'])
        sin_neg = np.sin(-ego_state['heading'])
        target_ego = np.array([
            sin_neg * target_delta[0] + cos_neg * target_delta[1],
            cos_neg * target_delta[0] - sin_neg * target_delta[1],
        ])

        steer, throttle, brake, _ = evaluator.controller.control_pid(
            plan_subset, ego_state['speed'], target_ego, waypoint_dt=0.5,
        )
        control = np.array([float(steer), float(throttle) - float(int(brake))])
        obs, reward, done, truncated, info = env.step(control)

        if done or truncated:
            print(f"  Scenario ended at frame {frame_id}")
            break

    env.close()
    print(f"\nDone! Output saved to: {output_dir}")


def main():
    parser = argparse.ArgumentParser(
        description="Visualize trajectory proposals with multi-scorer comparison"
    )
    parser.add_argument("--model-type", type=str, required=True,
                        choices=["diffusiondrive", "diffusiondrivev2"])
    parser.add_argument("--checkpoint", type=str, required=True)
    parser.add_argument("--plan-anchor-path", type=str, required=True)
    parser.add_argument("--v2-checkpoint", type=str, default=None,
                        help="DDv2 checkpoint for CoarseTopKScorer (required for DDv1)")
    parser.add_argument("--scenario-path", type=str, required=True)
    parser.add_argument("--output-dir", type=str, default=str(REPO_ROOT / "vis_proposals_output"))
    parser.add_argument("--eval-frames", type=int, default=40)

    args = parser.parse_args()

    # Default v2 checkpoint for DDv1 coarse_topk scorer
    if args.model_type == "diffusiondrive" and args.v2_checkpoint is None:
        args.v2_checkpoint = "/closed-loop-e2e/weights/navsimv2/DiffusionDriveV2/diffusiondrivev2_sel.ckpt"

    run_visualization(args)


if __name__ == "__main__":
    main()
