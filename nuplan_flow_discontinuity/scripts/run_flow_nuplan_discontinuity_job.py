#!/usr/bin/env python3
import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Sequence, Set


DEFAULT_REPLAN_STEPS = "1,2,5,10,20"


@dataclass
class DbShardItem:
    db_file: str
    tokens: List[str] = field(default_factory=list)

    @property
    def weight(self) -> int:
        return max(1, len(self.tokens))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run one Flow Planner nuPlan discontinuity eval shard.")
    parser.add_argument("--job-index", type=int, default=int(os.environ.get("JOB_COMPLETION_INDEX", "0")))
    parser.add_argument("--num-data-shards", type=int, default=int(os.environ.get("NUM_DATA_SHARDS", "8")))
    parser.add_argument("--replan-steps", default=os.environ.get("REPLAN_STEPS", DEFAULT_REPLAN_STEPS))
    parser.add_argument("--split", default=os.environ.get("NUPLAN_SPLIT", "val"))
    parser.add_argument("--scenario-filter", default=os.environ.get("SCENARIO_FILTER", "val14"))
    parser.add_argument("--simulation", default=os.environ.get("NUPLAN_SIMULATION", "closed_loop_nonreactive_agents"))
    parser.add_argument("--data-root", default=os.environ.get("NUPLAN_DATA_ROOT", "/avl-west/nuplan"))
    parser.add_argument("--maps-root", default=os.environ.get("NUPLAN_MAPS_ROOT", "/avl-west/nuplan/maps"))
    parser.add_argument(
        "--sensor-root",
        default=os.environ.get("NUPLAN_SENSOR_ROOT", "/avl-west/nuplan/nuplan-v1.1/sensor_blobs"),
    )
    parser.add_argument(
        "--db-root",
        default=os.environ.get("NUPLAN_DB_ROOT"),
        help="Defaults to ${data-root}/nuplan-v1.1/splits/${split}",
    )
    parser.add_argument("--nuplan-devkit-root", default=os.environ.get("NUPLAN_DEVKIT_ROOT", "/hugsim-storage/nuplan-devkit"))
    parser.add_argument("--flow-planner-root", default=os.environ.get("FLOW_PLANNER_ROOT", "/hugsim-storage/Flow-Planner"))
    parser.add_argument(
        "--config-path",
        default=os.environ.get("FLOW_PLANNER_CONFIG", "/hugsim-storage/Flow-Planner/config/flow_planner_model_config_nuplan.yaml"),
    )
    parser.add_argument(
        "--ckpt-path",
        default=os.environ.get("FLOW_PLANNER_CKPT", "/closed-loop-e2e/weights/nuplan/flow-planner/model.pth"),
    )
    parser.add_argument("--exp-root", default=os.environ.get("NUPLAN_EXP_ROOT", "/hugsim-storage/flow_planner_exp"))
    parser.add_argument("--manifest-dir", default=os.environ.get("SHARD_MANIFEST_DIR", "/hugsim-storage/flow_planner_exp/shards"))
    parser.add_argument("--shard-scan-workers", type=int, default=int(os.environ.get("SHARD_SCAN_WORKERS", "32")))
    parser.add_argument("--worker", default=os.environ.get("NUPLAN_WORKER", "ray_distributed"))
    parser.add_argument("--threads-per-node", type=int, default=int(os.environ.get("THREADS_PER_NODE", "32")))
    parser.add_argument("--cpus-per-sim", type=float, default=float(os.environ.get("CPUS_PER_SIM", "1")))
    parser.add_argument("--gpus-per-sim", type=float, default=float(os.environ.get("GPUS_PER_SIM", "0.25")))
    parser.add_argument("--dry-run", action="store_true", default=os.environ.get("DRY_RUN", "0") == "1")
    return parser.parse_args()


def parse_step_list(value: str) -> List[int]:
    steps = [int(x.strip()) for x in value.split(",") if x.strip()]
    if not steps or any(step < 1 for step in steps):
        raise ValueError(f"Invalid replan step list: {value}")
    return steps


def step_label(steps: int, dt_s: float = 0.1) -> str:
    interval_s = steps * dt_s
    rate_hz = 1.0 / interval_s
    if abs(rate_hz - round(rate_hz)) < 1e-6:
        rate = f"{int(round(rate_hz))}hz"
    else:
        rate = f"{str(rate_hz).replace('.', 'p')}hz"
    interval = str(interval_s).replace(".", "p")
    return f"{rate}_{interval}s_{steps}steps"


def read_filter_tokens(filter_path: Path) -> List[str]:
    text = filter_path.read_text()
    match = re.search(r"scenario_tokens:\s*(.*?)(?:\n\S|\Z)", text, flags=re.S)
    if not match:
        return []
    return [token.lower() for token in re.findall(r'"([0-9a-fA-F]+)"', match.group(1))]


def query_tokens_in_db(db_file: Path, wanted_tokens: Set[str]) -> List[str]:
    if not wanted_tokens:
        return []
    wanted_blobs = [sqlite3.Binary(bytes.fromhex(token)) for token in sorted(wanted_tokens)]
    placeholders = ",".join("?" for _ in wanted_blobs)
    with sqlite3.connect(str(db_file)) as connection:
        rows = connection.execute(
            f"SELECT hex(lidar_pc_token) FROM scenario_tag WHERE lidar_pc_token IN ({placeholders})",
            wanted_blobs,
        ).fetchall()
    return sorted({token_hex.lower() for (token_hex,) in rows if token_hex.lower() in wanted_tokens})


def greedy_shard(items: Sequence[DbShardItem], num_shards: int) -> List[List[DbShardItem]]:
    shards: List[List[DbShardItem]] = [[] for _ in range(num_shards)]
    weights = [0 for _ in range(num_shards)]
    for item in sorted(items, key=lambda x: x.weight, reverse=True):
        shard_idx = min(range(num_shards), key=lambda idx: weights[idx])
        shards[shard_idx].append(item)
        weights[shard_idx] += item.weight
    return shards


def hydra_list(values: Iterable[str]) -> str:
    return json.dumps(list(values), separators=(",", ":"))


def build_or_load_shards(args: argparse.Namespace) -> List[List[DbShardItem]]:
    db_root = Path(args.db_root or Path(args.data_root) / "nuplan-v1.1" / "splits" / args.split)
    filter_path = Path(args.flow_planner_root) / "flow_planner" / "nuplan_simulation" / "scenario_filter" / f"{args.scenario_filter}.yaml"
    manifest_dir = Path(args.manifest_dir) / args.scenario_filter / f"{args.num_data_shards}_shards"
    manifest_path = manifest_dir / "manifest.json"

    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
        return [[DbShardItem(**item) for item in shard] for shard in manifest["shards"]]

    manifest_dir.mkdir(parents=True, exist_ok=True)
    wanted_tokens = set(read_filter_tokens(filter_path))
    db_files = sorted(db_root.glob("*.db"))
    if not db_files:
        raise FileNotFoundError(f"No .db files found under {db_root}")

    items: List[DbShardItem] = []
    if wanted_tokens:
        with ThreadPoolExecutor(max_workers=max(1, args.shard_scan_workers)) as executor:
            futures = {executor.submit(query_tokens_in_db, db_file, wanted_tokens): db_file for db_file in db_files}
            for future in as_completed(futures):
                db_file = futures[future]
                tokens = future.result()
                if tokens:
                    items.append(DbShardItem(db_file=str(db_file), tokens=tokens))
    else:
        items = [DbShardItem(db_file=str(db_file), tokens=[]) for db_file in db_files]

    if not items:
        raise RuntimeError(f"No matching db files found for scenario_filter={args.scenario_filter}")

    shards = greedy_shard(items, args.num_data_shards)
    manifest = {
        "scenario_filter": args.scenario_filter,
        "split": args.split,
        "num_data_shards": args.num_data_shards,
        "total_db_files": len(items),
        "total_tokens": sum(len(item.tokens) for item in items),
        "shards": [[item.__dict__ for item in shard] for shard in shards],
    }
    manifest_path.write_text(json.dumps(manifest, indent=2))
    for idx, shard in enumerate(shards):
        shard_path = manifest_dir / f"shard_{idx:03d}.json"
        shard_path.write_text(json.dumps([item.__dict__ for item in shard], indent=2))
    return shards


def run() -> int:
    args = parse_args()
    replan_steps = parse_step_list(args.replan_steps)
    total_jobs = args.num_data_shards * len(replan_steps)
    if args.job_index < 0 or args.job_index >= total_jobs:
        raise ValueError(f"job-index {args.job_index} outside [0, {total_jobs})")

    replan_idx = args.job_index // args.num_data_shards
    shard_idx = args.job_index % args.num_data_shards
    replan_step = replan_steps[replan_idx]
    label = step_label(replan_step)

    shards = build_or_load_shards(args)
    shard = shards[shard_idx]
    db_files = [item.db_file for item in shard]
    tokens = sorted({token for item in shard for token in item.tokens})
    if not db_files:
        print(f"Shard {shard_idx} is empty; nothing to run.")
        return 0

    env = os.environ.copy()
    env["HYDRA_FULL_ERROR"] = "1"
    env["NUPLAN_DEVKIT_ROOT"] = args.nuplan_devkit_root
    env["NUPLAN_DATA_ROOT"] = args.data_root
    env["NUPLAN_MAPS_ROOT"] = args.maps_root
    env["NUPLAN_EXP_ROOT"] = args.exp_root
    env["REPLAN_DISCONTINUITY_DIR"] = str(
        Path(args.exp_root)
        / "discontinuity"
        / args.scenario_filter
        / args.simulation
        / f"replan_{label}"
        / f"shard_{shard_idx:03d}"
    )

    experiment_uid = (
        f"flow_planner_discontinuity/{args.scenario_filter}/{args.simulation}/"
        f"replan_{label}/shard_{shard_idx:03d}_of_{args.num_data_shards:03d}"
    )

    cmd = [
        sys.executable,
        str(Path(args.nuplan_devkit_root) / "nuplan" / "planning" / "script" / "run_simulation.py"),
        f"+simulation={args.simulation}",
        "planner=replan_flow_planner",
        f"planner.replan_flow_planner.replan_interval_steps={replan_step}",
        f"planner.replan_flow_planner.base_planner.config_path={args.config_path}",
        f"planner.replan_flow_planner.base_planner.ckpt_path={args.ckpt_path}",
        "scenario_builder=nuplan",
        f"scenario_builder.data_root={Path(args.data_root) / 'nuplan-v1.1' / 'splits' / args.split}",
        f"scenario_builder.map_root={args.maps_root}",
        f"scenario_builder.sensor_root={args.sensor_root}",
        f"scenario_builder.db_files={hydra_list(db_files)}",
        f"scenario_filter={args.scenario_filter}",
        "scenario_filter.scenario_types=null",
        f"scenario_filter.scenario_tokens={hydra_list(tokens)}" if tokens else "scenario_filter.scenario_tokens=null",
        "scenario_filter.num_scenarios_per_type=null",
        "scenario_filter.limit_total_scenarios=null",
        f"experiment_uid={experiment_uid}",
        "verbose=true",
        f"worker={args.worker}",
        f"worker.threads_per_node={args.threads_per_node}",
        f"number_of_cpus_allocated_per_simulation={args.cpus_per_sim}",
        f"number_of_gpus_allocated_per_simulation={args.gpus_per_sim}",
        "distributed_mode=SINGLE_NODE",
        "enable_simulation_progress_bar=false",
        "hydra.searchpath=[pkg://flow_planner.nuplan_simulation.scenario_filter,pkg://flow_planner.nuplan_simulation,pkg://nuplan.planning.script.config.common,pkg://nuplan.planning.script.experiments]",
    ]

    print(json.dumps({
        "job_index": args.job_index,
        "total_jobs": total_jobs,
        "replan_step": replan_step,
        "label": label,
        "shard_index": shard_idx,
        "num_data_shards": args.num_data_shards,
        "db_files": len(db_files),
        "tokens": len(tokens),
        "discontinuity_dir": env["REPLAN_DISCONTINUITY_DIR"],
    }, indent=2))
    print("COMMAND:")
    print(" ".join(cmd))

    if args.dry_run:
        return 0

    return subprocess.run(cmd, env=env, cwd=args.flow_planner_root).returncode


if __name__ == "__main__":
    raise SystemExit(run())
