# NexusSim all-in-one image

One environment for the **entire** NexusSim pipeline — convert, train, export, serve, rollout —
built on NVIDIA NRE (`nre-ga`) with IsaacSim added on top.

```
convert ──► train ──► export ──► serve ─┐
 (CPU)      (GPU)      (GPU)             ├─► rollout   (all in ONE image)
                                serve+rollout on ONE 3090  ◄─┘
```

## Why an image (not pip/conda)

NRE's `/app/run` (train/export/serve) ships **only** as the `nre-ga` container and is not
pip-installable, so the only "install once, do everything" unit is this Docker image. Heavy deps
(isaacsim, torch, tensorflow) plus the NexusSim code are baked at build; a developer can still mount a
fresh checkout at runtime (`NEXUSSIM_SRC`) to run edited code without rebuilding.

## Build (needs your own NGC access)

The base is gated. **We ship this Dockerfile, not a prebuilt image** — the built image contains NRE and
pushing it to a public registry violates NVIDIA's EULA. Build it yourself with your own NGC key; for a
cluster, push to a **private** registry.

The NexusSim code is taken from the build context (this Dockerfile lives in the repo), so **no repo auth
is needed** — just build from the repo root:

```bash
# 1) authenticate to NGC (username is literally $oauthtoken)
echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin

# 2) build from the repo root (context = the repo)
docker build -t nexussim-allinone -f docker/Dockerfile .
```

## Run — one command per stage

```bash
# CPU-only preprocessing
nexussim convert  --splits wod-perception_val

# GPU pipeline
nexussim train    --clip 10203656353524179475_7625_000_7645_000
nexussim export   --clip 10203656353524179475_7625_000_7645_000

# render server (foreground) — or fold it into rollout with `all`
nexussim serve

# closed-loop eval against a reachable serve
nexussim rollout  --clip 10203656353524179475_7625_000_7645_000

# serve (background) + rollout (foreground) on ONE 3090  ← the merged mode
nexussim all      --clip 10203656353524179475_7625_000_7645_000
```

`nexussim help` prints the usage.

### Data layout (point these at your own storage)

All paths derive from `DATA_ROOT` (default `/data`); override any individually:

| env | default | what |
|-----|---------|------|
| `DATA_ROOT`   | `/data`                     | base for everything below |
| `WOD_RAW`     | `$DATA_ROOT/wod_raw`        | Waymo raw tfrecords (convert input) |
| `PY123D_ROOT` | `$DATA_ROOT/py123d_arrow`   | converted py123d arrow |
| `R2S_ROOT`    | `$DATA_ROOT/reconstructions`| NuRec train/export outputs (usd-out) |
| `EVAL_OUT`    | `$DATA_ROOT/eval_out`       | rollout artifacts (gifs, metrics) |
| `CHECKPOINT`  | **(none — required)**       | path to the DrivoR `.pth` for `rollout`/`all` |
| `ARTIFACT_GLOB` | `$R2S_ROOT/*/output_static/*/usd-out/*.usdz` | which reconstructions `serve` loads |

Mount your data at `/data` (or set `DATA_ROOT`) and pass `CHECKPOINT=/path/to/drivor.pth`.

## Which NexusSim code runs

At startup the entrypoint resolves NexusSim and editable-installs it into `venv-sim`:
1. `NEXUSSIM_SRC` if set — a mounted checkout (e.g. a PVC). Best for active development: edit code, rerun,
   no rebuild.
2. else `NEXUSSIM_REPO` @ `NEXUSSIM_REF` if set — clone one.
3. else the code **baked into the image** at `/opt/nexussim` (the default; works out of the box).

## One GPU vs two

`nexussim all` runs serve + rollout on **one** 3090 (verified ~6.7 GB / 24 GB — plenty of headroom).
If a bigger scene ever OOMs, put them on two cards in the same container:
`SERVE_GPU=1 ROLLOUT_GPU=0 nexussim all --clip <CLIP>` (and request 2 GPUs on the pod).

## On a Kubernetes cluster

Build, push to a **private** registry the cluster can pull (with an image-pull secret), then a Job runs:

```yaml
image: <your-private-registry>/nexussim-allinone:latest
command: ["nexussim", "all", "--clip", "<CLIP>"]
env:
  - { name: DATA_ROOT,  value: /data }                    # your data PVC mount
  - { name: CHECKPOINT, value: /data/checkpoints/drivor.pth }
  - { name: NGC_API_KEY, valueFrom: { secretKeyRef: { name: ngc-api-key, key: NGC_API_KEY } } }
  # optional: NEXUSSIM_SRC=<mounted checkout> to run edited code without rebuilding
resources: { limits: { nvidia.com/gpu: 1 } }              # one GPU runs serve + rollout
# + mount your data PVC at $DATA_ROOT and dshm at /dev/shm
```
