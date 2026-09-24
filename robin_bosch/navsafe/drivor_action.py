"""NexusSim adapter for Robin Wang's `drivor_action` agent (bosch-summer, docs/deploy/dinov2_only_setting.md).

The agent is a flow-matching policy decoded from a fixed 64-noise vocabulary, a 6-member picker that ranks the 64
candidates, and optionally merged safety-RL adapters that re-decode the picked noise (`refine_pick`). Two settings:

  NAVSAFE_DA_SETTING=dinov2  the picker reads the policy's own DINOv2-S registers (deploy doc sections 1-7)
  NAVSAFE_DA_SETTING=best    the picker reads a separate GeoUP encoder, front camera x 4 frames (section 8)
  NAVSAFE_DA_SETTING=ext_drivor  no picker: DrivoR's released scorer ranks the 64 candidates (section 10a; policy/vocab of section 8)
  NAVSAFE_DA_SETTING=il19    section 9: the epoch-19 plain-IL policy with section 8's GeoUP picker, free_ids=true
  NAVSAFE_DA_SETTING=ext_gtrs    section 10b: GTRS-Dense V2-99 (NVlabs release) ranks the 64 candidates (policy/vocab of section 8)
  NAVSAFE_DA_ASSETS=<dir>    where picker/, geoup/, vocab/ live when they are not beside the checkpoint (il19: section 8's deploy dir)
  NAVSAFE_DA_REFINE=1        the checkpoint carries merged adapters: enable refine_pick (the AFTER system)

Nothing about the model is reimplemented here. The adapter builds Robin's `DrivorActionAgent` from his own hydra agent
config with exactly the overrides of his navtest recipe, turns each NexusSim observation into a navsim `AgentInput`
(4 history frames at the 0.5 s replan cadence, navsim camera calibration), and calls `agent.compute_trajectory`, so his
feature builders, picker ensemble and refine path run unchanged.

Robin's DrivoR fork is its own `navsim` package, which collides with SimScale's `navsim` on the worker's PYTHONPATH.
`load_model` evicts any imported `navsim` modules and puts the fork first; each NavSafe cell is its own process, so this
does not reach other rows.
"""

from __future__ import annotations

import os
import sys
from collections import deque
from pathlib import Path
from typing import Any, Dict

import numpy as np
import torch

from nexussim.evaluation.utils.constants import DEFAULT_CMD, NAVSIM_CMD_MAPPING
from nexussim.policy.registry import register_policy
from nexussim.policy.sensor.utils.frames import crop_to_navsim_aspect, renderer_bgr_to_rgb
from nexussim.policy.sensor_policy import SensorPolicy
from nexussim.utils.camera_utils import NAVSIM_CAM_CONFIGS, OPENSCENE_CAMERA_PARAMS

# Cameras the agent reads: the policy's four (drivor_action.yaml cam_f0/l0/r0/b0 = [3]); the GeoUP picker adds only
# CAM_F0 history, which the same render already provides.
CAMERAS = ("CAM_F0", "CAM_L0", "CAM_R0", "CAM_B0")
NAVSIM_KEY = {"CAM_F0": "cam_f0", "CAM_L0": "cam_l0", "CAM_R0": "cam_r0", "CAM_B0": "cam_b0"}
ALL_NAVSIM_KEYS = ("cam_f0", "cam_l0", "cam_l1", "cam_l2", "cam_r0", "cam_r1", "cam_r2", "cam_b0")
NUM_HISTORY = 4  # navsim AgentInput history: 4 frames at 2 Hz, the current one last


GTRS_CKPT = "/avl-west/navsafe_eval/aug_zoo/GTRS/gtrs_dense_vov.ckpt"   # = HF Zzxxxxxxxx/gtrs gtrs_dense_vov.ckpt (sha256 8bab5fb8...)
GTRS_VOCAB = "/avl-west/navsafe_eval/aug_zoo/SimScale/source/traj_final/16384.npy"


def _overrides(deploy: Path, setting: str, refine: bool, dinov2_weights: str) -> tuple[list[str], list[str]]:
    """The agent overrides of run_pdm_score in docs/deploy/dinov2_only_setting.md sections 4, 5, 8.2, 9.2 and 10.2."""
    if setting == "dinov2":
        members = [f"picker_full_kd1_s{s}" for s in range(3)] + [f"picker_reg_cpo_s{s}" for s in range(3)]
        scene = ["config.ext_scorer.vocab_picker.scene_source=policy"]
    elif setting in ("best", "il19"):
        members = [f"picker_geoup_kd1_cpoworst03_s{s}" for s in range(6)]
        scene = [
            "config.ext_scorer.vocab_picker.scene_source=geoup",
            f"config.ext_scorer.vocab_picker.geoup_checkpoint={deploy / 'geoup' / 'epoch_4.ckpt'}",
            "config.ext_scorer.vocab_picker.geoup_prediction_type=v",
            "config.ext_scorer.vocab_picker.geoup_schedule=gvp",
        ]
    elif setting in ("ext_drivor", "ext_gtrs"):
        members, scene = [], []
    else:
        raise ValueError(f"NAVSAFE_DA_SETTING must be dinov2, best, il19, ext_drivor or ext_gtrs, got {setting!r}")
    if setting == "il19":
        scene = scene + ["config.ext_scorer.vocab_picker.free_ids=true"]   # section 9.2: the picker on another policy's decodes
    models = [str(deploy / "picker" / m / "picker_best.pt") for m in members]
    for p in models:
        if not Path(p).is_file():
            raise FileNotFoundError(p)
    if setting == "ext_drivor":
        scorer = deploy / "scorer" / "nav1_30epochs_with_134k_simscale_bis_103ktrainval.pth"
        if not scorer.is_file():
            raise FileNotFoundError(scorer)
        ext = ["config.ext_scorer.kind=drivor", f"config.ext_scorer.checkpoint_path={scorer}",
               "config.ext_scorer.select=proposals", "config.ext_scorer.drivor.context=none"]
    elif setting == "ext_gtrs":
        scorer = Path(os.environ.get("NAVSAFE_DA_GTRS_CKPT", GTRS_CKPT))
        for f in (scorer, Path(GTRS_VOCAB)):
            if not f.is_file():
                raise FileNotFoundError(f)
        ext = ["config.ext_scorer.kind=gtrs", f"config.ext_scorer.checkpoint_path={scorer}", "config.ext_scorer.select=proposals",
               "config.ext_scorer.gtrs.backbone_type=vov", "config.ext_scorer.gtrs.context=vocab",
               "config.ext_scorer.gtrs.select_weights=dp", "config.ext_scorer.gtrs.context_size=0",
               f"config.ext_scorer.gtrs.vocab_path={GTRS_VOCAB}"]
    else:
        ext = ["config.ext_scorer.kind=vocab_picker", f"config.ext_scorer.checkpoint_path={models[0]}",
               "config.ext_scorer.select=proposals",
               "config.ext_scorer.vocab_picker.weights=v1", "config.ext_scorer.vocab_picker.ensemble=logit"]
    ov = [
        "config.ap.layers=4", "config.ap.heads=8", "config.ap.d_model=256", "config.ap.ffn_hidden=1024",
        "config.flow.prediction_type=v", "config.flow.schedule=linear", "config.flow.t_eps=0.05",
        "config.flow.num_denoise_steps=10", "config.ema.use_at_eval=true",
        *ext,
        "config.flow.prune_steps=0", "config.flow.prune_keep=16",
        "config.flow.num_val_samples=64", "config.flow.init_noise=vocab", "config.flow.init_noise_scale=1.0",
        "config.flow.init_noise_pool_mult=4", f"config.flow.init_noise_vocab_file={deploy / 'vocab' / 'noise_vocab_64.npy'}",
        f"config.image_backbone.model_weights={dinov2_weights}",
    ] + scene
    if refine:
        ov += [
            "config.refine.enabled=true", "config.refine.refine_pick=true", "config.refine.rank=8",
            "config.refine.alpha=8.0", "config.refine.active_steps=4", "config.refine.skip_last=true",
            "config.freeze_encoder=true",
        ]
    return ov, models


@register_policy("drivor_action")
class DrivorActionAdapter(SensorPolicy):
    """Robin's drivor_action agent (flow policy + vocabulary picker [+ merged safety-RL adapters])."""

    def __init__(self, checkpoint_path: str, **kwargs: Any):
        super().__init__(checkpoint_path, config_path=None, **kwargs)
        self.setting = os.environ.get("NAVSAFE_DA_SETTING", "dinov2").lower()
        self.refine = os.environ.get("NAVSAFE_DA_REFINE", "0") == "1"
        self.root = Path(os.environ.get("NAVSAFE_DA_ROOT", "/root/bosch-summer"))
        self.agent = None
        self._history: deque = deque(maxlen=NUM_HISTORY)
        self._last_frame = None

    # ── model ────────────────────────────────────────────────────────────────
    def load_model(self) -> None:
        fork = self.root / "DrivoR"
        for name in [m for m in sys.modules if m == "navsim" or m.startswith("navsim.")]:
            del sys.modules[name]
        sys.path.insert(0, str(fork))
        os.environ["NAVSIM_DEVKIT_ROOT"] = str(fork)

        import hydra
        from omegaconf import OmegaConf

        import navsim
        assert Path(navsim.__file__).resolve().is_relative_to(fork.resolve()), f"wrong navsim: {navsim.__file__}"

        ckpt = Path(self.checkpoint_path)
        deploy = Path(os.environ.get("NAVSAFE_DA_ASSETS") or ckpt.parent.parent)  # <deploy>/policy/<ckpt> unless assets live elsewhere
        weights = fork / "weights" / "vit_small_patch14_reg4_dinov2.lvd142m" / "model.safetensors"
        if not weights.is_file():
            raise FileNotFoundError(weights)
        overrides, models = _overrides(deploy, self.setting, self.refine, str(weights))

        cfg = OmegaConf.load(fork / "navsim/planning/script/config/common/agent/drivor_action.yaml")
        cfg.merge_with_dotlist(overrides)
        # list-valued override: merge_with_dotlist would parse the bracketed string, so set it directly
        if models:
            cfg.config.ext_scorer.vocab_picker.models = models
        cfg.checkpoint_path = str(ckpt)

        # torch >= 2.6 defaults torch.load to weights_only=True; Robin's checkpoints (and the pickers) pickle plain
        # python objects beside the tensors. They are his own artifacts, loaded as his code expects (torch 2.5). Left
        # patched for the life of this cell's process: the GeoUP encoder may load its checkpoint after initialize().
        _orig_load = torch.load

        def _load(*args: Any, **kw: Any):
            kw.setdefault("weights_only", False)
            return _orig_load(*args, **kw)

        torch.load = _load
        self.agent = hydra.utils.instantiate(cfg, _recursive_=True)
        self.agent.initialize()
        self.agent.eval()
        self.model = self.agent
        print(
            f"[drivor_action] loaded setting={self.setting} refine={self.refine} ckpt={ckpt} "
            f"pickers={[Path(m).parent.name for m in models] or 'none (ext scorer)'}"
        )

    def get_camera_configs(self) -> Dict[str, Dict[str, float]]:
        return {name: NAVSIM_CAM_CONFIGS[name] for name in CAMERAS}

    # ── AgentInput ───────────────────────────────────────────────────────────
    @staticmethod
    def _camera(image: np.ndarray | None, name: str):
        from navsim.common.dataclasses import Camera

        if image is None:
            return Camera()
        p = OPENSCENE_CAMERA_PARAMS[name]
        # BGR 1920x1120 render -> RGB 1920x1080 navsim frame (rows 0..1079 are the navsim frame; see frames.py)
        rgb = crop_to_navsim_aspect(renderer_bgr_to_rgb(image))
        return Camera(
            image=np.ascontiguousarray(rgb),
            sensor2lidar_rotation=np.asarray(p["sensor2lidar_rotation"], dtype=np.float64),
            sensor2lidar_translation=np.asarray(p["sensor2lidar_translation"], dtype=np.float64),
            intrinsics=np.asarray(p["intrinsics"], dtype=np.float64),
            distortion=np.asarray(p["distortion"], dtype=np.float64),
        )

    def _cameras(self, images: Dict[str, np.ndarray]):
        from navsim.common.dataclasses import Camera, Cameras

        cams = {k: Camera() for k in ALL_NAVSIM_KEYS}
        for name in CAMERAS:
            cams[NAVSIM_KEY[name]] = self._camera(images.get(name), name)
        return Cameras(**cams)

    @staticmethod
    def _local(vec: np.ndarray, heading: float) -> np.ndarray:
        c, s = np.cos(heading), np.sin(heading)
        return np.array([[c, s], [-s, c]]) @ np.asarray(vec[:2], dtype=np.float64)

    def _ego_status(self, snap: Dict[str, Any], cur: Dict[str, Any]):
        """navsim EgoStatus of a history frame: pose SE2-relative to the current frame, velocity and acceleration in the
        frame's own ego axes, the frame's one-hot driving command (navsim AgentInput conventions)."""
        from navsim.common.dataclasses import EgoStatus

        d = self._local(snap["position"] - cur["position"], cur["heading"])
        dh = (snap["heading"] - cur["heading"] + np.pi) % (2 * np.pi) - np.pi
        return EgoStatus(
            ego_pose=np.array([d[0], d[1], dh], dtype=np.float64),
            ego_velocity=self._local(snap["velocity"], snap["heading"]).astype(np.float32),
            ego_acceleration=self._local(snap["acceleration"], snap["heading"]).astype(np.float32),
            driving_command=np.asarray(snap["command"], dtype=np.int64),
        )

    def prepare_input(
        self,
        images: Dict[str, np.ndarray],
        ego_state: Dict[str, Any],
        scenario_data: Dict[str, Any],
        frame_id: int,
    ) -> Any:
        from navsim.common.dataclasses import AgentInput, Lidar

        if self._last_frame is not None and frame_id <= self._last_frame:
            self._history.clear()  # a new episode in the same process
        self._last_frame = frame_id
        snap = {
            "position": np.asarray(ego_state["position"][:2], dtype=np.float64),
            "heading": float(ego_state["heading"]),
            "velocity": np.asarray(ego_state["velocity"][:2], dtype=np.float64),
            "acceleration": np.asarray(ego_state.get("acceleration", [0.0, 0.0])[:2], dtype=np.float64),
            "command": NAVSIM_CMD_MAPPING.get(ego_state.get("command", 3), DEFAULT_CMD).copy(),
            "cameras": self._cameras(images),
        }
        self._history.append(snap)
        frames = list(self._history)
        # before 4 replans exist, repeat the oldest observed frame (the ego is still under logged replay then)
        frames = [frames[0]] * (NUM_HISTORY - len(frames)) + frames
        cur = frames[-1]
        return AgentInput(
            ego_statuses=[self._ego_status(f, cur) for f in frames],
            cameras=[f["cameras"] for f in frames],
            lidars=[Lidar() for _ in frames],
        )

    def run_inference(self, model_input: Any) -> Any:
        with torch.inference_mode():
            return self.agent.compute_trajectory(model_input, noise_seed=0)

    def parse_output(self, model_output: Any, ego_state: Dict[str, Any]) -> Dict[str, np.ndarray]:
        poses = np.asarray(model_output.poses, dtype=np.float64)  # (8, 3) x forward, y left, heading
        return {"trajectory": np.column_stack([poses[:, 1], poses[:, 0]])}
