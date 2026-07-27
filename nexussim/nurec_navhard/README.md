# navhard → NuRec gRPC recon pipeline (cogrob)

Per-scene reconstruction of **navhard** nuPlan clips for closed-loop DrivoR eval via
the `nurec_grpc` render backend. Source is **native 10 Hz raw nuPlan** (the older 2 Hz
NavSim/OpenScene path and the appearance experiments have been removed).

One "clip" = one nuPlan window (`scene_token`, ~20 s @ 10 Hz).

## Layout

Stages are separated into `aux/ train/ export/ eval/`, and **each scene has its own
materialized yaml** under every stage — no `__SCENE__` sed-and-apply, no clobbering:

```
aux/<scene>/aux.yaml
train/<scene>/{train-static, train-fullres, train-5cam}.yaml
export/<scene>/{export, render}.yaml
eval/<scene>/{arrow-dataset, eval}.yaml
_templates/   # __SCENE__ recipe sources — copy+fill to add a new scene (see below)
scripts/      # shared, arg-driven tooling (convert / batch)
```

Current scenes (native 10 Hz):

| scene_token | nuPlan log | window (t0,t1 µs) |
|---|---|---|
| `b971052f62165a1d10hz` | 2021.05.25.14.16.10_veh-35_01100_01664 | 1621967731500731, 1621967751000683 |
| `477045d84aa75534` | 2021.05.25.14.16.10_veh-35_00083_00485 | 1621966731500650, 1621966751000721 |
| `f2eae903542c56d3` | 2021.05.25.14.16.10_veh-35_01690_02183 | 1621968331500525, 1621968351000267 |
| `7c56367f5b9b55a0` | 2021.05.25.14.16.10_veh-35_02482_02649 | 1621969131501024, 1621969151000144 |

### Train variants (per scene, in `train/<scene>/`)
- `train-static.yaml`  — 3dgut_dynamic + static_rigids, half-res (subsample=2), `out_dir=output_static`.
- `train-fullres.yaml` — same, **full res** (subsample=1, 4× pixels — the de-blur knob), `out_dir=output_static_fullres`.
- `train-5cam.yaml`    — 5-camera variant, `out_dir=output_5cam`.
- `_templates/train-dynamic.yaml` — 3dgut_dynamic only (no static layer); kept as a recipe, not materialized per scene.

## Run order (per scene)

```bash
SCENE=b971052f62165a1d10hz
POD=horuan-nexussim
```

### 0. one-time: nvidia-ncore in the pod venv (CPU NCore writer)
```bash
kubectl exec $POD -- bash -lc \
  'export PATH=$HOME/.local/bin:$PATH; uv pip install --python /root/nexussim-venv/bin/python nvidia-ncore'
```

### 1. NCore conversion (in the pod — native 10 Hz nuPlan)
Builds `/avl-west/r2s_work/$SCENE/clips/$SCENE/pai_$SCENE.json` + camera/lidar shards.
Driven by `scripts/convert_nuplan10hz.py` (batch: `scripts/batch_convert10hz.sh`).
```bash
kubectl cp scripts/convert_nuplan10hz.py $POD:/tmp/convert_nuplan10hz.py
kubectl exec $POD -- /root/nuplan-conv/bin/python /tmp/convert_nuplan10hz.py <TOKEN> <LOG> <T0_US> <T1_US>
```

### 2. aux data (nre-tools, GPU ~30 min)
```bash
kubectl apply -f aux/$SCENE/aux.yaml
kubectl wait --for=condition=complete job/navhard-aux-$SCENE -n cogrob --timeout=3600s
```

### 3. link aux stores to the manifest base name (in the pod — REQUIRED before train)
`ncore-aux-data` names its outputs `<scene>.aux.*`; NRE training discovers them by the
manifest base `pai_<scene>.aux.*`. Create the symlinks:
```bash
kubectl exec $POD -- /root/nexussim-venv/bin/python -c \
  "from pathlib import Path; import sys; sys.path.insert(0,'/hugsim-storage/NexusSim'); \
   from nexussim.gs3d_converter.nurec_runner import _link_aux_to_manifest_base as L, _ncore_manifest as M; \
   cd=Path('/avl-west/r2s_work/$SCENE/clips/$SCENE'); L(cd, M(cd)); print('linked')"
```

### 4. train (nre-ga, GPU). Pick a variant.
Do NOT delete the Job while the GPU looks idle — the checkpoint save to CephFS is slow.
```bash
kubectl apply -f train/$SCENE/train-fullres.yaml     # or train-static / train-5cam
kubectl wait --for=condition=complete job/navhard-trainstatic-fullres-$SCENE -n cogrob --timeout=7200s
```

Steps 2–4 for a batch of scenes: `TRAIN=fullres scripts/batch_recon.sh <scene> [<scene> ...]`.

### 5. export → usd-out (nre-ga, GPU)
```bash
kubectl apply -f export/$SCENE/export.yaml     # PLYs + tracks + usd-out/*.usdz
kubectl apply -f export/$SCENE/render.yaml     # optional: sanity-render PNGs/MP4 along the rig
```

### 6. serve-grpc
The shared `../nurec_serving/serve-grpc.yaml` globs the usd-out; point/symlink it at this
recon's `output_*/usd-out/*.usdz`, then:
```bash
kubectl rollout restart deploy/nurec-grpc-server -n cogrob
```

### 7. eval (DrivoR closed-loop, py123d Arrow scenario source)
First build the scene's Arrow (ego/boxes/traffic-lights/map, native 10 Hz nuplan_test):
```bash
# arrow-dataset.yaml is the py123d-conversion dataset config for this scene (window baked in).
# Feed it to py123d-conversion (in the pod) writing to /avl-west/py123d_arrow_nuplan10hz.
```
Then run closed-loop eval:
```bash
kubectl apply -f eval/$SCENE/eval.yaml
```

## Adding a new scene
Copy the `_templates/*` files, fill in the token (and, for the arrow, the
`__LOG__/__SCENE__/__T0__/__T1__` placeholders), and write them under the four stage
dirs as `<newscene>/…`. That keeps every scene's config a distinct file on disk.
