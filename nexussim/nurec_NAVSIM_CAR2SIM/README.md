# navsim / nuPlan 10 Hz → NuRec recon via the **car2sim** recipe (best-quality)

End-to-end pipeline to reconstruct a **navhard** (NavSim / OpenScene / nuPlan) clip
at **native 10 Hz** and reconstruct it with NVIDIA NRE using the
**`car2sim_6cam`** recipe, then run closed-loop DrivoR eval via `nurec_grpc`.

**Why car2sim** — after comparing Waymo-shell (`3dgut_dynamic` + static_rigids),
`_base_3dgut_dynamic`, full-res, and no-lidar variants on b9710, **car2sim was
the best overall**. It is NOT a static recipe: it extends
`_base_3dgut_dynamic_road_semantic`, so it ships
- `dynamic_rigids` + `dynamic_deformables` (moving vehicles / pedestrians),
- a `road` semantic layer,
- **MCMC densification** (target ≤ 2 M gaussians — fixes starved pedestrians / jitter),
- **temporal appearance** (`fourier_features_dim_20`, *properly composed* so it
  does NOT hit the autograd-inplace crash you get from `++`-ing it à la carte),
- **40 000 iterations** (vs 30 000 default — more per-image supervision, which
  our 8-camera rig needs).

Config: `configs/apps/prod/Hyperion-8.1/car2sim_6cam.yaml` (built into the
`nre-ga` image). We drive it with nuPlan sensor/label overrides — see step 4.

---

## Files (run in order)

| # | file | what |
|---|---|---|
| 0 | `0-enum_navhard.py` | enumerate navhard MetaDrive descriptors → `(token,log,t0,t1,split,map)` TSV work list |
| 1 | `1-convert_nuplan10hz.py` | raw nuPlan (10 Hz) → NCore V4 store (in-pod, `/root/nuplan-conv` venv) |
| 2 | `2-aux.yaml` | ncore-aux-data (egomask / sseg / lidar-sseg — GPU ~30 min) |
| 3 | `3-arrow-dataset.yaml` | py123d Arrow scenario source (ego/boxes/map/route) for eval |
| 4 | `4-train-car2sim.yaml` | car2sim recipe → `output_car2sim` (GPU, 40 k, ~35–55 min); separates only MOVING objects |
| 4b | `4b-train-car2sim-static.yaml` + `car2sim_6cam_static.yaml` | **recommended**: car2sim **+ static_rigids** → `output_car2sim_static`. Best quality AND every boxed object (moving + parked) is its own editable layer |
| 5 | `5-export.yaml` | plys + tracks + `usd-out/*.usdz` (what serve-grpc serves) |
| 6 | `6-eval-logreplay.yaml` | closed-loop DrivoR eval via nurec_grpc |
| — | `navhard_scenes.tsv` | the 421 navhard scenes (token/log/t0/t1/split/map), from `0-enum_navhard.py` |

Placeholders: `__SCENE__` = navsim scene_token (= NCore clip_id = arrow log_name),
`__LOG__` = nuPlan db name (in `splits/test/`), `__T0__ __T1__` = window µs.

---

## 0. Prereqs (one-time, in the pod `horuan-nexussim`)

The dev pod is ephemeral — if it was recreated, rebuild the conversion venv
(`/root/nuplan-conv` has py123d[nuplan] + nvidia-ncore + nuplan-devkit):

```bash
python3 -m venv /root/nuplan-conv
/root/nuplan-conv/bin/pip install -e "/hugsim-storage/py123d[nuplan]"   # SQLAlchemy etc.
/root/nuplan-conv/bin/pip install nuplan-devkit                          # the `nuplan` module (extra doesn't include it!)
# register our arrow dataset config so py123d-conversion can select it:
cp 3-arrow-dataset.yaml /hugsim-storage/py123d/src/py123d/script/config/conversion/dataset/nuplan-navhard.yaml
```

## 1. Pick a scene + convert to 10 Hz NCore (in the pod, NOT a k8s Job)

navhard scenes come from `/avl-west/navsim/test_navsim_logs/test/*.pkl`; each
frame carries `scene_token`, `log_name`, `timestamp`. The `log_name` == the
nuPlan **db file name**, which lives in `/avl-west/nuplan/nuplan-v1.1/splits/test/`.
Take t0/t1 = min/max frame timestamp of the token (~19.5 s window).

```bash
# copy the db to local disk (network PVC read is 8x slower)
DST=/tmp/nuplan_local/nuplan-v1.1/splits/test; mkdir -p $DST
cp -n /avl-west/nuplan/nuplan-v1.1/splits/test/<LOG>.db $DST/
# build the NCore store (~3–4 min): 8 cameras + flattened lidar
PYTHONPATH=/hugsim-storage/NexusSim /root/nuplan-conv/bin/python \
  1-convert_nuplan10hz.py <TOKEN> <LOG> <T0_US> <T1_US>
# -> /avl-west/r2s_work/<TOKEN>/clips/<TOKEN>/pai_<TOKEN>.json + 10 shards
```

## 2. aux data + link to manifest base (REQUIRED before train)

```bash
sed 's/__SCENE__/<TOKEN>/g' 2-aux.yaml | kubectl apply -f -
kubectl wait --for=condition=complete job/navhard-aux-<TOKEN> -n cogrob --timeout=3600s
# ncore-aux-data names outputs <scene>.aux.* ; NRE discovers pai_<scene>.aux.* — symlink:
kubectl exec horuan-nexussim -n cogrob -- /root/nuplan-conv/bin/python -c "
from pathlib import Path
from nexussim.gs3d_converter.nurec_runner import _link_aux_to_manifest_base as L, _ncore_manifest as M
import sys; sys.path.insert(0,'/hugsim-storage/NexusSim')
cd=Path('/avl-west/r2s_work/<TOKEN>/clips/<TOKEN>'); L(cd, M(cd)); print('linked')"
```

## 3. arrow (eval scenario source) — in the pod, `/root/nuplan-conv`

```bash
PYTHONPATH=/hugsim-storage/NexusSim PY123D_DATA_ROOT=/avl-west/py123d_arrow_nuplan10hz \
  /root/nuplan-conv/bin/py123d-conversion dataset=nuplan-navhard \
  "dataset.parser.scenes=[[<LOG>, <TOKEN>, <T0>, <T1>]]"
# -> /avl-west/py123d_arrow_nuplan10hz/logs/nuplan_test/<TOKEN>/*.arrow  + maps/nuplan/
```

## 4. TRAIN — car2sim (the winning recipe)

```bash
sed 's/__SCENE__/<TOKEN>/g' 4-train-car2sim.yaml | kubectl apply -f -
```
Key overrides baked into `4-train-car2sim.yaml` (all REQUIRED for nuPlan):
- 8 nuPlan cameras (`camera_pcam_*`) + `lidar_top_360fov`, `n_train_sample_lidar_rays=0`.
- `dataset.cuboid_tracks_params.track_label_sources=[GT_ANNOTATION]` (else 0 tracks).
- class routing: `VEHICLE,BICYCLE`→dynamic_rigids, `PEDESTRIAN`→dynamic_deformables
  (NVIDIA default names don't match `NuPlanBoxDetectionLabel.*` → dynamic layers train empty).
- dynamic init `camera-dynamic-tracks` + `fill_with_random_points` (flattened lidar
  seeds ~0 points per cuboid).
- road init `lidar-rig-trajectory` (car2sim defaults to `lidar_ground_mesh_road`
  which fails on our lidar).
- **`checkpoint.artifact.mesh.ground.enabled=false`** — the road ground-mesh export
  crashes at checkpoint save with `ZeroDivisionError: weights sum to zero` (our
  flattened nuPlan lidar gives a degenerate road surface: ~18 cm z-noise vs WOD's
  2 cm → Delaunay leaves isolated vertices → smoothing divides by zero). car2sim
  saves ONLY ONE checkpoint at step 40 000, so this crash wastes the whole run.
  The ground mesh is a USD export artifact only — recon renders gaussians, so
  disabling it costs nothing. (`smoothing_passes=0` is rejected: pydantic gt=0;
  even 1 pass still crashes — it's the geometry, not the pass count.)
- node anti-affinity avoids `ry-gpu-05` (that node runs 3090 at ~3.4 it/s vs ~18–24).

## 5. export → usd-out

```bash
sed -e 's/output_3dgutdyn/output_car2sim/g' \
    -e 's/navhard-export-__SCENE__/navhard-export-car2sim-__SCENE__/' \
    -e 's/__SCENE__/<TOKEN>/g' 5-export.yaml | kubectl apply -f -
```

## 6. serve + eval (closed-loop DrivoR, log-replay)

```bash
# point serve-grpc at car2sim usd (same clip_id => one recon per scene at a time):
kubectl patch deploy nurec-grpc-server -n cogrob --type=json -p \
  '[{"op":"replace","path":"/spec/template/spec/containers/0/args/0",
     "value":"set -x\n/app/run serve-grpc --host 0.0.0.0 --enable-editing-actors --renderer default --artifact-glob '"'"'/avl-west/r2s_work/*/output_car2sim/*/usd-out/*.usdz'"'"'\n"}]'
# then (40-frame log-replay; drop the two seds for the full 190-frame run):
sed -e 's/eval-logreplay-nuplan-__SCENE__/eval-logreplay-car2sim-__SCENE__/' \
    -e 's#navhard_logreplay_nuplan_#navhard_logreplay_nuplan_car2sim_#g' \
    -e 's/--eval-frames 190 --ego-replay-frames 190/--eval-frames 40 --ego-replay-frames 40/' \
    -e 's/__SCENE__/<TOKEN>/g' 6-eval-logreplay.yaml | kubectl apply -f -
# result: .../navhard_logreplay_nuplan_car2sim_<TOKEN>/out/py123d_arrow_nuplan10hz_<TOKEN>/
#   visualization/combined.gif  +  frames/*  +  metrics.json
```

---

## Gotchas / lessons (see also the agent memory files)

- **Recipes aren't dataset-agnostic**: the Waymo `3dgut_dynamic` is a thin shell
  (`_base_3dgut_dynamic` + `_waymo_mixin` that only wires Waymo camera_ids/subsample,
  which we already override). The substance (densification, ppisp, sky, bilateral)
  is in the shared base. So "Waymo vs base" ≈ same; the real levers are MCMC /
  temporal appearance / iters / seed — all of which car2sim already bundles.
- **temporal appearance à la carte crashes**: `++model.layers.*.fourier_features_dim=5`
  or `optimize_track_albedo=true` on top of the Waymo base crash at step 0
  (autograd inplace in the SH-features collector). car2sim composes it correctly →
  no crash. If you need temporal appearance, use a recipe that composes it.
- **nuPlan lidar is degraded** (flattened, single-timestamp-per-sweep, no per-ray
  timing → NRE can't motion-compensate). Measured road surface: ~18 cm z-noise
  (p90) vs WOD's 2 cm. This buries cm-scale raised lane markers and breaks the
  ground mesh. Final recon is OK because cameras refine it; a *no-lidar* road
  (random seed, free background) recovers lane markings better but blurs the
  background — the clean fix is no-lidar-road + MCMC + 40 k (untested here).
- **eval is dominated by `render_vis`** (BEV over the whole-Vegas map): fixed by an
  ego-bbox cull in `nexussim/evaluation/vis_utils.py` (uncommitted working-tree edit
  that the eval job overlays via `git ls-files -mo`). Keeps eval ~1.2 s/frame.
- **util-policy denials** (`pods resources utilization too low`): retry submits on a
  loop; the first GPU job that lands raises utilization and the rest go through.
- **same clip_id ⇒ serialize evals**: b9710 output_car2sim and output_static share
  the scene_id, so serve one recon at a time.

## b9710 result (40-frame log-replay)
car2sim: epdms **0.674**, driving_score **0.46**, collisions 0 — best of the
Waymo-shell / base / fullres / roadcam set. (log-replay metrics are recon-agnostic;
the win is visual: sharper background + cleaner dynamics via MCMC/40k/temporal-appearance.)
