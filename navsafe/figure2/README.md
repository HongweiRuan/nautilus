# Figure 2 — one rendered scenario per taxonomy leaf

Sixteen closed-loop DrivoR rollouts, two per leaf, rendered through the NuRec
gRPC server so the frames can be cropped straight into Figure 2 of the paper.

These runs are **for pictures, not for numbers.** They use the frozen recipes,
but the episode length (20 replay + 180 eval frames) is a figure setting, not
the benchmark's; nothing here should be quoted as a score. The benchmark
numbers live in `/avl-west/runs/20260827-editing90/`.

## Run it

    ./submit_figure2.sh          # 16 jobs, one scenario each, 1 GPU each
    ./status.sh                  # job state + frames produced so far

Change the scenarios by editing `scenarios.txt` and re-submitting; a Job whose
name already exists is deleted and replaced, so re-running one line is cheap.

Knobs, as environment variables on `submit_figure2.sh`:

| variable | default | what it does |
|---|---|---|
| `OUTROOT` | `/avl-west/runs/20260902-paper-figure2-drivor` | where the footage lands |
| `REPLAY`  | `20`  | frames of logged-ego replay before the policy takes over |
| `EVALF`   | `180` | frames the policy drives; `20 + 180` is the full 20 s episode |

## What you get, and what to crop

    <OUTROOT>/<leaf>.<token>/
    ├── frames/<NNNNN>/cam_f0.jpg   front camera, UNANNOTATED  <- the figure panel
    │                  cam_l0.jpg   left camera
    │                  cam_b0.jpg   rear camera
    │                  topdown.png  BEV of the same frame      <- the inset
    ├── visualization/combined.mp4  the whole episode, for FINDING the frame
    ├── navsafe_metrics.json        written only if the episode ran to the end
    └── eval.log

`NEXUSSIM_NO_OVERLAY=1` and `NEXUSSIM_NO_CAM_MAP_LINES=1` are set, so
`cam_f0.jpg` is the renderer's own pixels — no HUD, no plan ribbon, no
projected lane lines. Those annotations are burned in and cannot be removed
later, which is why the benchmark runs (which keep them, for debugging) are the
wrong source for a figure. The BEV is written separately and is unaffected.

Workflow that works: scrub `visualization/combined.mp4` to find the moment,
read the frame number off it, then take `frames/<NNNNN>/cam_f0.jpg`.

## The sixteen

Two per leaf, listed in `scenarios.txt`. They are the two per leaf whose
`20260827-editing90` run reached the full episode — a proxy for "this host
renders end to end", not an aesthetic judgement. Swap freely once you have
looked at the footage.

## How it is put together

`submit_figure2.sh` uploads `run_figure2_worker.sh` as a ConfigMap and renders
`templates/figure2.yaml` once per line of `scenarios.txt` into `rendered/`.
Each Job runs one scenario:

1. **Preflight** — checkpoint, recipe, Arrow, four reconstructions. Each of
   these has previously cost a job forty minutes of environment build before
   failing, so they are answered in the first two seconds.
2. **Environment** — a shared venv on the PVC, or a build if none is usable.
   **Checked 2026-09-02: there is no usable shared venv** (`ns-venv` is gone,
   `navsafe_bundle_repo/venv` is py3.11 with a dangling interpreter symlink), so
   every job builds its own — the same `uv sync --all-extras --python 3.12` that
   `pods/horuan-nexussim.yaml` runs, ~15 min. The uv cache is **pod-local**, as
   in that pod, not the 62 GB one on `/avl-west`: the PVC cache sits on a
   different filesystem from the venv, so uv cannot hardlink and copies all ~360
   packages instead, which is where the editing90 jobs' ~40 min went. The worker
   still probes for a shared venv, so one that reappears is picked up without
   editing anything; extra candidates go in `SHARED_VENVS`.
3. **Kit shader cache** — restored from
   `/avl-west/navsafe_dev/kitcache/kitcache-3090-<driver>.tar`. Without it every
   job spends ~7.7 min inside `AppLauncher` compiling materials and ray-tracing
   pipelines onto an empty stage, into caches that die with the pod. Measured
   2026-08-31: 467 s cold, 10.5 s warm. The tar is keyed on driver version; a
   miss only costs the compile, it never fails the job. Refresh instructions are
   in the script, beside the code that reads it.
4. **Renderer** — `serve-grpc` over this host's four sub-clips only, then a
   check that all four appear in its scene list. A renderer asked for a scene it
   does not hold **falls back to raster silently**; on a metrics run that shows
   up as a bad number, on a figure run it is a blurry panel nobody catches until
   review.
5. **Rollout** — `eval_py123d.py` with `--recipe`, `--traffic-mode navsafe`,
   DrivoR under LQR control at a 5 Hz replan rate.

One GPU per job: `serve-grpc` and the IsaacSim rollout share a 3090 at ~6.7 GB
with the harmonizer off, which is also how the benchmark's own frames were
rendered. Sixteen jobs is sixteen GPUs, inside the twenty this account may hold.
Turning the harmonizer on would need a second GPU per job (its weights sit
beside the scene cache and take `serve-grpc` to ~18 GB) — and would make these
frames look unlike the rest of the paper.

Nodes: the six cogrob reserved nodes. `ry-gpu-13` and `ry-gpu-14` are left out
deliberately.

## Cost

Per job: ~15 min venv + ~4 min renderer start + ~10 s Kit boot + the rollout.
Sixteen in parallel on sixteen GPUs finish together.

`--enable-vis` writes a per-frame BEV and end-of-run GIFs. It used to dominate
the run (6.3 s/frame, 86.9% of it projecting the whole city map); the world-space
bbox cull in `nexussim/evaluation/vis_utils.py` landed, so it no longer does. The
GIFs are 200+ MB each, so budget ~1 GB per scenario on `/avl-west`.
