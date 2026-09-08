# FDpi^k: extending the policy panel

Submit from an account the utilization webhook is not throttling:

    ./submit.sh ready   # 4 cells, a 6th panel agent, nothing new to build
    ./submit.sh vla     # SimWAM: original + on + off + drivearena, all at once

The VLA jobs sit in the **public queue** — no reservation, us-west or
us-central, a 3090 or an A10 (both 24 GB), cpu 2, because in the public pool
the CPU request is usually what a pod waits on. The PVCs are `rook-cephfs`,
the cluster-wide class rather than a region-pinned one, so a us-central node
mounts them fine; reads just cross regions.

## What FDpi^k needs from a model

Not a checkpoint. A **forward hook on one named module**, whose pooled
activation is the feature; `HOOK_SPECS` in the evaluator is keyed by the agent's
class name. Every candidate below runs an ITERATIVE head — diffusion or
autoregressive decoding — so a tap inside it fires many times per anchor and the
feature would depend on the step count rather than the picture. The tap must be
the last thing computed ONCE from the image, which is exactly where the panel's
`drivor_f0` already taps (`image_backbone:output`).

## Verdict, from each adapter's source

Two things decide it: how many cameras the model reads (our farms hold CAM_F0
only, so a surround model would be fed mostly unchanged real footage), and
whether a single-fire tap exists.

| model | cameras | can | tap point / reason |
|---|---|---|---|
| **SimWAM** | 1 front, no history | **yes** | `video_expert.pre_dit` — `infer_action` calls it once on the frame's VAE latents, then enters 10-step action diffusion |
| **MTDrive** | 1 front | yes | Qwen2.5-VL vision tower, once in prefill; the LM then decodes text |
| **ReCogDrive** | 1 front + 4 ego **poses** | yes | InternVL3 vision encoder, once; DiT planner runs 5 steps after |
| **DriveVLA-W0** | 2 frames @1 Hz | yes | Emu3 VQ tokenizer, once; flow matching runs 10 steps after |
| **DriveLaW** | 4 frames @2 Hz | yes, but | LTX VAE encode of the conditioning frames, once — however `forward_test` **generates a 768x1344x18-frame video per anchor**, roughly ten times SimWAM's cost |
| AutoVLA | CAM_F0 + CAM_L1 + CAM_R1, 4 frames each | **no** | two of its three views would be unchanged real footage |
| ResWorld | 6 nuScenes surround @256x704 | **no** | same, worse; and it has no navsim agent at all |

Anchors available per model, counted on `manifest_zfix2.json` — a model that
conditions on earlier frames loses anchors near a scenario's start, because the
farm holds only frames inside the common intersection:

| requirement | anchors | share |
|---|---|---|
| 1 frame (SimWAM, MTDrive, ReCogDrive) | 4,175 | 100% |
| 2 frames @1 Hz (DriveVLA-W0) | 3,870 | 92.7% |
| 4 frames @2 Hz (DriveLaW) | 3,678 | 88.1% |

A per-model N is fine and needs no special handling: `compute_fd.py` intersects
on `sample_tokens` and drops rows carrying a `skip_reason`, so each model is
compared against its own real-frame side on its own anchors.

## `jobs/` — ready, nothing new to build

`ddv2_sel` (`diffusiondrivev2_sel_agent_front_only`) is already wired into all
four places the evaluator needs and was simply never run: the published matrix
used 5 of the 6 agents the script offers. Front-camera only. Four cells, the
same 4,155 tokens as the published numbers.

## `vla/` + `jobs_vla/` — SimWAM

SimWAM first because it is the only candidate that needs **one frame and no
history**, so it keeps all 4,175 anchors and has the cheapest inference — its
video branch is thrown away at inference by design (an isolated attention mask
keeps action tokens independent of future frames), unlike DriveLaW which runs a
video model per anchor.

Three stages, and only the middle one needs the model:

    token_table.py        A  ego status + frame order per anchor, once, in the
                             evaluator's env; the GPU stage then needs no navsim
    feature_dump_vla.py   B  the hook, in the VLA venv — the only process the
                             model exists in. Writes the evaluator's own npz
                             contract, so stage C is the evaluator's script
    vla_fdpik_worker.sh   C  scripts/compute_fd.py, unchanged

One GPU, not two. The closed-loop sweep excludes SimWAM because it OOMs sharing
a pod with the renderer; FDpi^k reads frames off the PVC, there is no renderer,
and the card is the model's alone — that constraint does not apply here.

### What is verified, and what the first job will find out

Verified from source: the camera requirement, the anchor counts, that
`pre_dit` is called once before the diffusion loop, that the npz contract
matches, and that every path the jobs reference exists on the PVC
(`SimWAM-RL.pt` 12 GB, the diffsynth cache, the repo's `configs/src/navsim`).

**All verified by running it**, 2026-09-07: the token table (4,163 anchors),
the venv, `build()`, a 12 GB bf16 checkpoint loading onto a 24 GB card without
OOM, the JPEG preprocessing path, and — past 200 anchors without the guard
tripping — that the wrapped `pre_dit` fires exactly once per anchor and pools
to a stable (B, D).

There is no separate probe: the four sides go out together and whichever
reaches the model first answers all three. That is safe because the dumper
**refuses loudly** — it aborts the run — if the hook fires more than once for
an anchor, rather than silently averaging over diffusion steps, and it records
a per-anchor `skip_reason` instead of failing the job when a single forward
throws. A rendered side that finishes before the original waits up to 3 h for
the reference rather than exiting with its features written and no FD.

`nurec_zfix2` is not among the sides: the four submitted are `original`,
`eval_on_zfix2`, `eval_off_zfix2` and `drivearena_zfix2`.

### The other three, and what each still needs

Now that SimWAM has run the whole chain end to end, the remaining work is
known rather than guessed. Stage A and stage C are model-independent; each
model is one adapter function in `feature_dump_vla.py`.

| model | server shape | tap | still needed |
|---|---|---|---|
| **MTDrive** | `MTDriveServer(model_path)` — already a class, `.infer(image: np.ndarray, history, status)` takes pixels directly | `model.visual` (Qwen2.5-VL vision tower) is an `nn.Module`, so the plain forward-hook path applies | the 4-pose ego history |
| **ReCogDrive** | `ReCogDriveServer(...)` — also a class, `.infer(image: np.ndarray, ...)`, and `load_image_array` already takes an array | `vlm_hidden_state` — the VLM summary that conditions the diffusion planner, i.e. the planner-side bottleneck the published panel taps, not a vision encoder | the 4-pose ego history |
| **DriveVLA-W0** | construction inline in `main()`, like SimWAM was | Emu3 VQ tokenizer, once per anchor | the same `build()` split SimWAM needed (`cf6b9bb6`), plus 2 frames @1 Hz |

Neither MTDrive nor ReCogDrive needs the preprocessing split SimWAM needed
(`b257b9a7`): both take a numpy frame directly.

**The one shared gap is the ego history.** Both `infer()` signatures take a
`history` alongside the status, and stage A currently records only
`cmd_onehot`, `vel` and `acc` — the three SimWAM uses. Adding the 4 recent ego
poses is a new field in `token_table.py`; it is backward compatible (SimWAM
ignores it) but rebuilding the table pays the slow CephFS log scan again, so it
is worth doing once for all three rather than per model.

One detail to carry over when writing those adapters: the closed-loop adapters
call `crop_to_navsim_aspect` on the renderer's frame before handing it over.
The farm JPEGs are already navsim-shaped, so check whether that crop is a
no-op here rather than assuming it either way.
