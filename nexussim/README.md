# NexusSim on Nautilus (cogrob) — NuRec gRPC pipeline manifests

Cluster-specific k8s manifests for the NuRec **gRPC** closed-loop eval pipeline.
These carry the cogrob specifics (the `avl-west-vol` / `horuan-hugsim-vol` PVCs,
RTX-3090 affinity, `nautilus.io/reservation=cogrob` toleration, `ngc-pull` /
`ngc-api-key` secrets). The dataset-agnostic *how it works* lives in the public
repo: [`docs/nurec_grpc_eval.md`](../../NexusSim/docs/nurec_grpc_eval.md) (this
is the **Part B — Kubernetes** path).

## Run order (per clip)

Set `CLIP` (underscore id, e.g. `10247954040621004675_2180_000_2200_000`) and
`CLIPNAME` (dashed, `…-2180-000-2200-000`). Templated manifests take both via
`sed`.

| # | Step | Manifest | Notes |
|---|---|---|---|
| 1 | Scenario Arrow (+ HD map) | `data_prep/convert-wod-arrow.yaml` | converts a whole WOD split; run once per split |
| 2 | Train (static separation) | `nurec_training/train-1gpu-static.yaml` | GPU, ~30-60 min; produces `output_static/<clip>/checkpoints` |
| 3 | Export → usd-out | `nurec_training/export-static.yaml` | produces the gRPC-servable `usd-out/last.usdz` |
| 4 | Serve | `nurec_serving/serve-grpc.yaml` | Deployment + Service `nurec-grpc:8080`; **restart** after a new clip (below) |
| 5 | Eval | `nurec_eval/eval-py123d-grpc.yaml` | `__REMOVE__=--remove-agents` for background-only (all objects dropped from render + sim state), empty for full |

Steps 1 and 2 are independent (can run in parallel). Step 3 needs 2; step 5 needs
3 (served) + 1.

## Instantiate + submit

```bash
CLIP=10247954040621004675_2180_000_2200_000
CLIPNAME=$(echo $CLIP | tr _ -)

# 2. train
sed -e "s/__CLIP__/$CLIP/g" -e "s/__CLIPNAME__/$CLIPNAME/g" \
    nurec_training/train-1gpu-static.yaml | kubectl apply -f -

# 3. export (after train Complete)
sed -e "s/__CLIP__/$CLIP/g" -e "s/__CLIPNAME__/$CLIPNAME/g" \
    nurec_training/export-static.yaml | kubectl apply -f -

# 4. serve once, then restart to pick up each new clip
kubectl apply -f nurec_serving/serve-grpc.yaml
kubectl rollout restart deploy/nurec-grpc-server -n cogrob

# 5. eval — __REMOVE__=--remove-agents => background only (render + state)
sed -e "s/__CLIP__/$CLIP/g" -e "s/__CLIPNAME__/$CLIPNAME/g" -e "s/__REMOVE__/--remove-agents/g" \
    nurec_eval/eval-py123d-grpc.yaml | kubectl apply -f -
```

## Notes / gotchas

- **The overlay recipe** the train job copies in
  (`/avl-west/nre_overlays/3dgut_dynamic_static.yaml`) is a PVC copy of the repo
  master `nexussim/gs3d_converter/configs/3dgut_dynamic_static.yaml`; re-sync it
  after changing the master. Its `# @package _global_` must stay the **first
  line** or Hydra drops the `static_rigids` layer.
- **serve-grpc caches the scene list at start-up** — always `rollout restart`
  after exporting a new clip, or its `usd-out` won't be served.
- **Nautilus utilization policy** can deny new GPU jobs when the account holds
  many idle GPU requests ("utilization too low"); free idle pods first.
- The eval derives the gRPC render anchor from the Arrow (no sidecar/pkl); it
  only needs the reconstruction served + the clip's Arrow converted.

## Related existing manifests

- `nurec_training/train-1gpu-3dgutdyn.yaml`, `train-8gpu-*.yaml`, `export-*.yaml`
  — other recipe/scale variants.
- `wod-pod.yaml`, `nurec-jobs.yaml` — earlier ad-hoc pods/jobs.
