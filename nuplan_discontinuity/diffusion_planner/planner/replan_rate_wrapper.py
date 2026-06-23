import csv
import math
import os
import uuid
from pathlib import Path
from typing import Dict, List, Optional, Type

import numpy as np

from nuplan.common.actor_state.ego_state import EgoState
from nuplan.common.actor_state.state_representation import TimePoint
from nuplan.planning.simulation.observation.observation_type import Observation
from nuplan.planning.simulation.planner.abstract_planner import (
    AbstractPlanner,
    PlannerInitialization,
    PlannerInput,
)
from nuplan.planning.simulation.trajectory.abstract_trajectory import AbstractTrajectory
from nuplan.planning.simulation.trajectory.interpolated_trajectory import InterpolatedTrajectory


def _angle_diff(a: float, b: float) -> float:
    return float(math.atan2(math.sin(a - b), math.cos(a - b)))


def _speed(state: EgoState) -> float:
    velocity = state.dynamic_car_state.rear_axle_velocity_2d
    return float(math.hypot(velocity.x, velocity.y))


def _acceleration(state: EgoState) -> float:
    acceleration = state.dynamic_car_state.rear_axle_acceleration_2d
    return float(math.hypot(acceleration.x, acceleration.y))


def _pose_distance(a: EgoState, b: EgoState) -> float:
    return float(math.hypot(a.rear_axle.x - b.rear_axle.x, a.rear_axle.y - b.rear_axle.y))


class ReplanRateWrapperPlanner(AbstractPlanner):
    """Wraps a nuPlan planner and only refreshes the plan every N simulation steps."""

    def __init__(
        self,
        base_planner: AbstractPlanner,
        replan_interval_steps: int = 1,
        output_dir: Optional[str] = None,
        sample_interval_s: Optional[float] = None,
        max_logged_overlap_s: float = 2.0,
    ) -> None:
        assert replan_interval_steps >= 1, "replan_interval_steps must be >= 1"
        self._base_planner = base_planner
        self._replan_interval_steps = int(replan_interval_steps)
        self._output_dir = output_dir or os.environ.get(
            "REPLAN_DISCONTINUITY_DIR",
            "/hugsim-storage/diffusion_planner_exp/discontinuity",
        )
        self._sample_interval_s = sample_interval_s
        self._max_logged_overlap_s = max_logged_overlap_s

        self._last_trajectory: Optional[AbstractTrajectory] = None
        self._last_replan_iteration_index: Optional[int] = None
        self._log_path: Optional[Path] = None
        self._log_fields = [
            "planner_name",
            "replan_interval_steps",
            "replan_interval_s",
            "replan_rate_hz",
            "iteration_index",
            "time_us",
            "steps_since_previous_replan",
            "current_pose_jump_m",
            "current_yaw_jump_rad",
            "current_speed_jump_mps",
            "current_accel_jump_mps2",
            "next_pose_jump_m",
            "next_yaw_jump_rad",
            "overlap_samples",
            "overlap_mean_pose_jump_m",
            "overlap_max_pose_jump_m",
            "overlap_mean_yaw_jump_rad",
            "overlap_max_yaw_jump_rad",
        ]

    def name(self) -> str:
        return f"{self._base_planner.name()}_replan_{self._replan_interval_steps}_steps"

    def observation_type(self) -> Type[Observation]:
        return self._base_planner.observation_type()

    def initialize(self, initialization: PlannerInitialization) -> None:
        self._base_planner.initialize(initialization)
        Path(self._output_dir).mkdir(parents=True, exist_ok=True)
        self._log_path = Path(self._output_dir) / f"{self.name()}_{os.getpid()}_{uuid.uuid4().hex[:8]}.csv"
        with self._log_path.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=self._log_fields)
            writer.writeheader()

    def compute_planner_trajectory(self, current_input: PlannerInput) -> AbstractTrajectory:
        iteration_index = int(current_input.iteration.index)
        should_replan = (
            self._last_trajectory is None
            or self._last_replan_iteration_index is None
            or iteration_index - self._last_replan_iteration_index >= self._replan_interval_steps
            or not self._last_trajectory.is_in_range(current_input.iteration.time_point)
        )

        if should_replan:
            previous_trajectory = self._last_trajectory
            previous_replan_index = self._last_replan_iteration_index
            new_trajectory = self._base_planner.compute_trajectory(current_input)
            if previous_trajectory is not None:
                self._record_boundary_discontinuity(
                    current_input=current_input,
                    previous_trajectory=previous_trajectory,
                    new_trajectory=new_trajectory,
                    previous_replan_index=previous_replan_index,
                )
            self._last_trajectory = new_trajectory
            self._last_replan_iteration_index = iteration_index
            return new_trajectory

        return self._trim_cached_trajectory(current_input.iteration.time_point)

    def _infer_sample_interval_us(self, trajectory: AbstractTrajectory) -> int:
        if self._sample_interval_s is not None:
            return max(1, int(round(self._sample_interval_s * 1e6)))

        sampled = trajectory.get_sampled_trajectory()
        if len(sampled) >= 2:
            dt_us = int(sampled[1].time_us - sampled[0].time_us)
            if dt_us > 0:
                return dt_us

        return 100_000

    def _trim_cached_trajectory(self, current_time: TimePoint) -> AbstractTrajectory:
        assert self._last_trajectory is not None
        trajectory = self._last_trajectory
        step_us = self._infer_sample_interval_us(trajectory)

        start_us = current_time.time_us
        end_us = trajectory.end_time.time_us
        if start_us >= end_us:
            return trajectory

        time_points = [TimePoint(start_us)]
        t_us = start_us + step_us
        while t_us <= end_us:
            time_points.append(TimePoint(t_us))
            t_us += step_us

        if len(time_points) == 1:
            time_points.append(TimePoint(end_us))
        elif time_points[-1].time_us < end_us:
            time_points.append(TimePoint(end_us))

        return InterpolatedTrajectory(trajectory.get_state_at_times(time_points))

    def _record_boundary_discontinuity(
        self,
        current_input: PlannerInput,
        previous_trajectory: AbstractTrajectory,
        new_trajectory: AbstractTrajectory,
        previous_replan_index: Optional[int],
    ) -> None:
        if self._log_path is None:
            return

        current_time = current_input.iteration.time_point
        step_us = self._infer_sample_interval_us(new_trajectory)
        replan_interval_s = self._replan_interval_steps * step_us / 1e6
        replan_rate_hz = 1.0 / replan_interval_s if replan_interval_s > 0 else float("nan")

        old_current = previous_trajectory.get_state_at_time(current_time)
        new_current = new_trajectory.get_state_at_time(current_time)

        overlap_pose_jumps: List[float] = []
        overlap_yaw_jumps: List[float] = []
        max_overlap_us = int(round(self._max_logged_overlap_s * 1e6))
        overlap_end_us = min(
            previous_trajectory.end_time.time_us,
            new_trajectory.end_time.time_us,
            current_time.time_us + max_overlap_us,
        )

        t_us = current_time.time_us
        while t_us <= overlap_end_us:
            t = TimePoint(t_us)
            old_state = previous_trajectory.get_state_at_time(t)
            new_state = new_trajectory.get_state_at_time(t)
            overlap_pose_jumps.append(_pose_distance(old_state, new_state))
            overlap_yaw_jumps.append(abs(_angle_diff(old_state.rear_axle.heading, new_state.rear_axle.heading)))
            t_us += step_us

        next_pose_jump = float("nan")
        next_yaw_jump = float("nan")
        next_time = TimePoint(current_time.time_us + step_us)
        if previous_trajectory.is_in_range(next_time) and new_trajectory.is_in_range(next_time):
            old_next = previous_trajectory.get_state_at_time(next_time)
            new_next = new_trajectory.get_state_at_time(next_time)
            next_pose_jump = _pose_distance(old_next, new_next)
            next_yaw_jump = abs(_angle_diff(old_next.rear_axle.heading, new_next.rear_axle.heading))

        row: Dict[str, object] = {
            "planner_name": self.name(),
            "replan_interval_steps": self._replan_interval_steps,
            "replan_interval_s": replan_interval_s,
            "replan_rate_hz": replan_rate_hz,
            "iteration_index": int(current_input.iteration.index),
            "time_us": int(current_time.time_us),
            "steps_since_previous_replan": (
                int(current_input.iteration.index) - int(previous_replan_index)
                if previous_replan_index is not None
                else ""
            ),
            "current_pose_jump_m": _pose_distance(old_current, new_current),
            "current_yaw_jump_rad": abs(_angle_diff(old_current.rear_axle.heading, new_current.rear_axle.heading)),
            "current_speed_jump_mps": abs(_speed(old_current) - _speed(new_current)),
            "current_accel_jump_mps2": abs(_acceleration(old_current) - _acceleration(new_current)),
            "next_pose_jump_m": next_pose_jump,
            "next_yaw_jump_rad": next_yaw_jump,
            "overlap_samples": len(overlap_pose_jumps),
            "overlap_mean_pose_jump_m": float(np.mean(overlap_pose_jumps)) if overlap_pose_jumps else float("nan"),
            "overlap_max_pose_jump_m": float(np.max(overlap_pose_jumps)) if overlap_pose_jumps else float("nan"),
            "overlap_mean_yaw_jump_rad": float(np.mean(overlap_yaw_jumps)) if overlap_yaw_jumps else float("nan"),
            "overlap_max_yaw_jump_rad": float(np.max(overlap_yaw_jumps)) if overlap_yaw_jumps else float("nan"),
        }

        with self._log_path.open("a", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=self._log_fields)
            writer.writerow(row)
