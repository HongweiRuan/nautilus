 #!/usr/bin/env python3
"""
Visualize trajectory proposals with scores from multiple scorers on BEV & RGB.

For each frame, generates:
  - BEV images per scorer with all proposals color-coded + top-K labeled
  - RGB images per scorer with top-K proposals projected onto front camera
  - Side-by-side comparison grid

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
from collections import deque

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
# Drawing helpers
# ---------------------------------------------------------------------------

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


def pick_display_indices(scores, n_top=5, n_mid=3):
    """Pick top-K and some medium-scored indices for labeling."""
    order = np.argsort(scores)[::-1]  # descending
    top_idx = order[:n_top].tolist()
    mid_start = len(order) // 2 - n_mid // 2
    mid_idx = order[mid_start:mid_start + n_mid].tolist()
    return top_idx, mid_idx


# ---------------------------------------------------------------------------
# BEV Drawing
# ---------------------------------------------------------------------------

def draw_proposals_bev(topdown_frame, proposals_ego, scores, scorer_name,
                       frame_id, ego_position, pred_position, pred_heading,
                       selected_traj_world=None, screen_size=800, bev_scaling=None):
    """
    Draw trajectory proposals on a BEV image with score labels.

    Args:
        topdown_frame: (H, W, 3) BEV image from MetaDrive
        proposals_ego: (N, 8, 2) proposals in ego frame [lateral, forward]
        scores: (N,) scores for each proposal
        scorer_name: str for legend
        frame_id: int
        ego_position: (2,) current ego position for centering
        pred_position: (2,) ego position at prediction time
        pred_heading: float heading at prediction time
        selected_traj_world: (T, 2) selected trajectory in world coords
        screen_size: int pixel size
        bev_scaling: float pixels per meter from MetaDrive renderer
    """
    img = topdown_frame.copy()
    scaling = bev_scaling if bev_scaling is not None else (screen_size / 20.0)
    center_px = screen_size // 2

    # Try to get actual scaling from the frame
    # We'll compute from known distances if needed
    def world_to_pixel(world_pos):
        dx_m = world_pos[0] - ego_position[0]
        dy_m = world_pos[1] - ego_position[1]
        dx_px = dx_m * scaling
        dy_px = dy_m * scaling
        pixel_x = int(center_px + dx_px)
        pixel_y = int(center_px - dy_px)
        return pixel_x, pixel_y

    def is_in_bounds(px, py):
        return 0 <= px < screen_size and 0 <= py < screen_size

    cos_h = np.cos(pred_heading)
    sin_h = np.sin(pred_heading)

    scores_norm = normalize_scores(scores)
    top_idx, mid_idx = pick_display_indices(scores, n_top=5, n_mid=3)
    label_idx = set(top_idx + mid_idx)

    N = len(proposals_ego)

    # Pass 1: Draw all proposals as thin lines
    for i in range(N):
        t = scores_norm[i]
        color = score_to_color(t)
        thickness = 1

        points = []
        for wp in proposals_ego[i]:
            world_x = pred_position[0] + cos_h * wp[1] - sin_h * wp[0]
            world_y = pred_position[1] + sin_h * wp[1] + cos_h * wp[0]
            px, py = world_to_pixel(np.array([world_x, world_y]))
            if is_in_bounds(px, py):
                points.append((px, py))

        if len(points) > 1:
            for j in range(len(points) - 1):
                cv2.line(img, points[j], points[j + 1], color, thickness)

    # Pass 2: Draw labeled proposals with thick lines + score text
    font = cv2.FONT_HERSHEY_SIMPLEX
    for i in label_idx:
        t = scores_norm[i]
        color = score_to_color(t)
        thickness = 2 if i in top_idx else 2

        points = []
        for wp in proposals_ego[i]:
            world_x = pred_position[0] + cos_h * wp[1] - sin_h * wp[0]
            world_y = pred_position[1] + sin_h * wp[1] + cos_h * wp[0]
            px, py = world_to_pixel(np.array([world_x, world_y]))
            if is_in_bounds(px, py):
                points.append((px, py))

        if len(points) > 1:
            for j in range(len(points) - 1):
                cv2.line(img, points[j], points[j + 1], color, thickness)

            # Label at endpoint
            ep = points[-1]
            label = f"{scores[i]:.3f}"
            # Background rectangle for readability
            (tw, th), _ = cv2.getTextSize(label, font, 0.35, 1)
            cv2.rectangle(img, (ep[0] + 2, ep[1] - th - 2),
                          (ep[0] + tw + 4, ep[1] + 2), (0, 0, 0), -1)
            cv2.putText(img, label, (ep[0] + 3, ep[1] - 1),
                        font, 0.35, (255, 255, 255), 1)

    # Draw selected trajectory (thick yellow)
    if selected_traj_world is not None and len(selected_traj_world) > 0:
        sel_points = []
        for wp in selected_traj_world:
            px, py = world_to_pixel(wp)
            if is_in_bounds(px, py):
                sel_points.append((px, py))
                cv2.circle(img, (px, py), 3, (0, 255, 255), -1)
        if len(sel_points) > 1:
            for j in range(len(sel_points) - 1):
                cv2.line(img, sel_points[j], sel_points[j + 1], (0, 255, 255), 2)

    # Ego marker
    cv2.circle(img, (center_px, center_px), 6, (255, 0, 0), -1)

    # Legend
    overlay = img.copy()
    cv2.rectangle(overlay, (5, 5), (220, 75), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.6, img, 0.4, 0, img)
    cv2.putText(img, f"Frame: {frame_id}", (10, 20), font, 0.5, (255, 255, 255), 1)
    cv2.putText(img, f"Scorer: {scorer_name}", (10, 40), font, 0.5, (255, 255, 255), 1)
    cv2.putText(img, f"Proposals: {N}, labeled top-5 + mid-3", (10, 58), font, 0.35, (200, 200, 200), 1)
    cv2.putText(img, "Blue=Low, Green=Mid, Red=High", (10, 72), font, 0.35, (200, 200, 200), 1)

    return img


# ---------------------------------------------------------------------------
# RGB Drawing
# ---------------------------------------------------------------------------

def draw_proposals_rgb(cam_img, proposals_ego, scores, scorer_name,
                       frame_id, cam_config, n_show=5):
    """
    Draw top-N proposals projected onto camera image with score labels.

    Args:
        cam_img: (H, W, 3) front camera image
        proposals_ego: (N, 8, 2) proposals in ego frame [lateral, forward]
        scores: (N,) scores
        scorer_name: str
        frame_id: int
        cam_config: dict with camera params
        n_show: number of top proposals to draw
    """
    img = cam_img.copy()
    H, W = img.shape[:2]
    font = cv2.FONT_HERSHEY_SIMPLEX

    order = np.argsort(scores)[::-1]
    top_idx = order[:n_show]
    scores_norm = normalize_scores(scores)

    # Draw from lowest score to highest so best is on top
    for rank, i in enumerate(reversed(top_idx)):
        traj = proposals_ego[i]  # (8, 2) [lateral, forward]
        pixels, valid = project_ego_waypoints_to_camera(traj, cam_config, img.shape)

        t = scores_norm[i]
        color = score_to_color(t)
        thickness = 3 if rank < 2 else 2  # top-2 thicker

        # Draw polyline
        valid_pixels = []
        for k in range(len(pixels)):
            if valid[k]:
                px, py = int(pixels[k][0]), int(pixels[k][1])
                if 0 <= px < W and 0 <= py < H:
                    valid_pixels.append((px, py))

        if len(valid_pixels) > 1:
            pts = np.array(valid_pixels, dtype=np.int32)
            cv2.polylines(img, [pts], False, color, thickness, cv2.LINE_AA)

            # Score label at the furthest visible point
            ep = valid_pixels[-1]
            label = f"{scores[i]:.3f}"
            (tw, th), _ = cv2.getTextSize(label, font, 0.45, 1)
            # Offset labels to avoid overlap
            offset_y = -15 * (n_show - 1 - rank)
            lx = ep[0] + 5
            ly = ep[1] + offset_y
            ly = max(th + 5, min(H - 5, ly))
            lx = max(5, min(W - tw - 5, lx))
            cv2.rectangle(img, (lx - 1, ly - th - 2), (lx + tw + 1, ly + 2), (0, 0, 0), -1)
            cv2.putText(img, label, (lx, ly), font, 0.45, color, 1, cv2.LINE_AA)

    # HUD
    overlay = img.copy()
    cv2.rectangle(overlay, (0, 0), (W, 30), (0, 0, 0), -1)
    cv2.addWeighted(overlay, 0.6, img, 0.4, 0, img)
    cv2.putText(img, f"Frame {frame_id}  |  {scorer_name}  |  Top-{n_show} proposals",
                (10, 22), font, 0.55, (255, 255, 255), 1)

    return img


# ---------------------------------------------------------------------------
# Comparison grid
# ---------------------------------------------------------------------------

def make_comparison_grid(images, labels, cols=3):
    """Create a labeled grid image from list of images."""
    font = cv2.FONT_HERSHEY_SIMPLEX
    n = len(images)
    rows = (n + cols - 1) // cols

    # Resize all to same size
    h0, w0 = images[0].shape[:2]
    grid_h = h0 * rows
    grid_w = w0 * cols
    grid = np.zeros((grid_h, grid_w, 3), dtype=np.uint8)

    for idx, (img, label) in enumerate(zip(images, labels)):
        r, c = idx // cols, idx % cols
        resized = cv2.resize(img, (w0, h0))
        grid[r * h0:(r + 1) * h0, c * w0:(c + 1) * w0] = resized

    return grid


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
        frame_selected = {}

        for scorer_name, scorer in scorers.items():
            result = scorer.select_best(
                model_output,
                ego_state=ego_state,
                frame_idx=frame_id,
            )
            all_scores = result["scores"][0].cpu().numpy() if torch.is_tensor(result["scores"]) else result["scores"]
            if len(all_scores.shape) > 1:
                all_scores = all_scores[0]
            best_idx = int(result["best_idx"][0]) if torch.is_tensor(result["best_idx"]) else int(result["best_idx"])

            frame_scores[scorer_name] = all_scores  # (N,)
            # Get selected trajectory in world coords
            best_traj_ego = proposals_ego[best_idx]  # (8, 2) [lateral, forward]
            cos_h = np.cos(ego_state['heading'])
            sin_h = np.sin(ego_state['heading'])
            world_x = ego_state['position'][0] + cos_h * best_traj_ego[:, 1] - sin_h * best_traj_ego[:, 0]
            world_y = ego_state['position'][1] + sin_h * best_traj_ego[:, 1] + cos_h * best_traj_ego[:, 0]
            frame_selected[scorer_name] = np.stack([world_x, world_y], axis=1)

        # --- Render BEV base ---
        try:
            topdown_base = env.render(
                mode="top_down",
                semantic_map=True,
                film_size=(10000, 10000),
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

        # --- Draw per scorer ---
        frame_out = output_dir / f"{frame_id:05d}"
        frame_out.mkdir(parents=True, exist_ok=True)

        bev_images = []
        rgb_images = []
        scorer_labels = []

        for scorer_name in ["coarse_topk", "epdms_fast", "epdms_ego"]:
            sc = frame_scores[scorer_name]
            sel = frame_selected[scorer_name]

            # BEV
            bev_img = draw_proposals_bev(
                topdown_base, proposals_ego, sc, scorer_name,
                frame_id, ego_state['position'][:2],
                ego_state['position'][:2], ego_state['heading'],
                selected_traj_world=sel, screen_size=800,
                bev_scaling=bev_scaling,
            )

            cv2.imwrite(str(frame_out / f"bev_{scorer_name}.png"), bev_img)
            bev_images.append(bev_img)

            # RGB
            if cam_img is not None and cam_cfg is not None:
                rgb_img = draw_proposals_rgb(
                    cam_img, proposals_ego, sc, scorer_name,
                    frame_id, cam_cfg, n_show=5,
                )
                cv2.imwrite(str(frame_out / f"rgb_{scorer_name}.png"), rgb_img)
                rgb_images.append(rgb_img)

            scorer_labels.append(scorer_name)

        # --- Comparison grids ---
        if len(bev_images) == 3:
            bev_grid = make_comparison_grid(bev_images, scorer_labels, cols=3)
            cv2.imwrite(str(frame_out / "comparison_bev.png"), bev_grid)

        if len(rgb_images) == 3:
            rgb_grid = make_comparison_grid(rgb_images, scorer_labels, cols=3)
            cv2.imwrite(str(frame_out / "comparison_rgb.png"), rgb_grid)

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
