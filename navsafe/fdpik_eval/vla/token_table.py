#!/usr/bin/env python3
"""Stage A: what each FDpi^k anchor needs besides its image, dumped once.

The NavSafe VLA adapters want more than pixels -- a driving-command one-hot,
velocity and acceleration, and for two of them a short history of EARLIER
frames. Pixels and frame order come from the pinned manifest; the ego status
only navsim has, so this runs once in the evaluator's env and caches the result
for the GPU stage, which then needs no navsim at all.

Output: one json, token -> {image, prev[], cmd_onehot, vel, acc}.
`image` and `prev` are farm-RELATIVE (<log>/CAM_F0/<stem>.jpg), so the same
table serves the real frames and every rendered variation.
"""
import argparse, json, os, sys

ap = argparse.ArgumentParser()
ap.add_argument("--manifest", default="/avl-west/render_quality_eval/manifest_zfix2.json")
ap.add_argument("--out", default="/avl-west/fidelity_eval/fdpik_vla/token_table.json")
ap.add_argument("--history", type=int, default=4,
                help="how many earlier frames to record; the widest any model needs")
a = ap.parse_args()

man = json.load(open(a.manifest))["scenes"]

# navsim's own loader for the ego status. Imported late so a --dry-run of the
# frame side does not require the evaluator's env.
from navsim.common.dataloader import SceneLoader          # noqa: E402
from navsim.common.dataclasses import SceneFilter, SensorConfig  # noqa: E402
from hydra.utils import instantiate                        # noqa: E402
from omegaconf import OmegaConf                            # noqa: E402

SPLITS = os.environ.get(
    "NAVSIM_SPLITS",
    "/avl-west/drivearena_bench/unified_evaluator/navsim/planning/script/config/common/train_test_split")
base = OmegaConf.load(f"{SPLITS}/scene_filter/navtest.yaml")
tokens_wanted = {f["scene_token"] for sc in man for f in sc["frames"] if f["is_navtest"]}
base.tokens = sorted(tokens_wanted)
scene_filter: SceneFilter = instantiate(base)

loader = SceneLoader(
    data_path=os.environ["NAVSIM_DATA_ROOT"],
    original_sensor_path=os.environ["OPENSCENE_DATA_ROOT"],
    scene_filter=scene_filter,
    sensor_config=SensorConfig.build_no_sensors(),   # status only; no image decode
)

status = {}
for tok in loader.tokens:
    ai = loader.get_agent_input_from_token(tok)
    es = ai.ego_statuses[-1]
    status[tok] = {
        "cmd_onehot": [float(x) for x in es.driving_command],
        "vel": [float(x) for x in es.ego_velocity],
        "acc": [float(x) for x in es.ego_acceleration],
    }
print(f"ego status for {len(status)} of {len(tokens_wanted)} anchors", file=sys.stderr)

table, missing_hist = {}, 0
for sc in man:
    order = sorted(sc["frames"], key=lambda f: f["i"])
    by_i = {f["i"]: f for f in order}
    for f in order:
        if not f["is_navtest"]:
            continue
        tok = f["scene_token"]
        if tok not in status:
            continue
        prev = []
        for k in range(1, a.history + 1):
            p = by_i.get(f["i"] - k)
            if p is None:
                break
            prev.append(p["data_path"])
        if len(prev) < a.history:
            missing_hist += 1
        table[tok] = dict(image=f["data_path"], prev=prev,   # prev[0] = i-1
                          log=sc["log"], i=f["i"], **status[tok])

os.makedirs(os.path.dirname(a.out), exist_ok=True)
json.dump(table, open(a.out, "w"))
print(f"wrote {len(table)} anchors to {a.out}; "
      f"{missing_hist} have fewer than {a.history} predecessors in the common set",
      file=sys.stderr)
