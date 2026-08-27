#!/usr/bin/env python3
"""Build the NCore V4 store for ONE navhard scene from RAW nuPlan (native 10Hz).

Mirrors convert_navsim.py but uses NuplanLogReader (raw nuPlan sqlite via
py123d[nuplan]) instead of NavsimLogReader (2Hz OpenScene pkl). Run IN the pod
with the /root/nuplan-conv venv (has py123d[nuplan] + nvidia-ncore). The scene's
db must be at <nuplan_data_root>/nuplan-v1.1/splits/test/<log>.db (copy it to
/tmp/nuplan_local for fast local read).

  /root/nuplan-conv/bin/python convert_nuplan10hz.py <TOKEN> <LOG> <T0_US> <T1_US>

Writes /avl-west/r2s_work/<TOKEN>/clips/<TOKEN>/pai_<TOKEN>.json + 8 camera
shards + lidar shard. Next: aux.yaml -> link aux -> train.
"""
import sys, time, os
from pathlib import Path

NUPLAN_DATA_ROOT = os.environ.get("NUPLAN_DATA_ROOT", "/tmp/nuplan_local")
SENSOR_ROOT = "/avl-west/nuplan/nuplan-v1.1/sensor_blobs"
MAPS_ROOT = "/avl-west/nuplan/maps"
OUT_ROOT = "/avl-west/r2s_work"


def main() -> None:
    token, log, t0, t1 = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    sys.path.insert(0, "/hugsim-storage/NexusSim")
    from nexussim.gs3d_converter.log_ingestion import NuplanLogReader
    from nexussim.gs3d_converter.ncore_bridge import NCoreBridge

    work_dir = Path(OUT_ROOT) / token
    reader = NuplanLogReader(
        nuplan_data_root=NUPLAN_DATA_ROOT,
        sensor_root=SENSOR_ROOT,
        maps_root=MAPS_ROOT,
        scenes=[(log, token, t0, t1)],
        split="nuplan_test",
    )
    t = time.time()
    scene = next(iter(reader.iter_scenes()))
    print(f"[{token}] clip={scene.clip_id} frames={scene.n_frames} "
          f"cams={len(scene.camera_metas)} ({time.time()-t:.0f}s to build scene)",
          flush=True)
    t = time.time()
    clip_dir = NCoreBridge.prepare(scene, work_dir)
    print(f"[{token}] NCore prepare OK in {time.time()-t:.0f}s -> {clip_dir}", flush=True)
    for p in sorted(Path(clip_dir).glob("*")):
        print(f"   {os.path.getsize(p) if p.is_file() else 0:>12}  {p.name}", flush=True)


if __name__ == "__main__":
    main()
