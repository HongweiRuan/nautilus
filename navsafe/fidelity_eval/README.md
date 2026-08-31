# render_quality_eval — NavSafe NuRec vs DriveArena, head to head

One question: **on the scenarios we have reconstructions for, how much better is our
NuRec render than DriveArena's generation?** Not a comparison against
`unified_evaluator`'s published cells — those were measured on a different token set at
a different sample size, and FID does not survive a change of N (the *identical*
official DriveArena render scores 41.80 on 11156 tokens and 123.21 on 310).

## Scope

| | |
|---|---:|
| scenarios (4/4 reconstructions, minus DriveArena's training logs) | **392** |
| logs | 118 |
| frames, 2 Hz — the FID/FVD set | **16 707** |
| of which navtest tokens — the FDπᵏ set | **4 373** |
| FVD windows (16 consecutive frames, stride 8) | **~1 568** |

15 scenarios were dropped because their log is inside DriveArena's `dreamer_train` /
`dreamer_val` split. Leaving them in would score the generative side on scenes it was
trained on.

FID and FVD use **all** 2 Hz frames in each 20 s window, not just the navtest tokens:
they only need images, so restricting them would throw away 70% of the sample for
nothing. Only FDπᵏ needs navtest tokens, because only those frames can build a valid
policy input.

## What makes it comparable

Five constraints, each enforced in code rather than by convention:

1. **One frame set, pinned before anything renders.** `build_manifest.py` writes
   `manifest.json`; every stage reads it. Both sides write to
   `<log>/CAM_F0/<image_token>.jpg` — the *original* sensor-blob filename — so "the
   same frame" is mechanical.
2. **Each renderer at its own native resolution.** Resolution is part of what a
   renderer delivers, not a nuisance variable to be equalised away: NavSafe hands a
   policy **1920×1080**, DriveArena can only hand it **400×224**. unified_evaluator's
   own reference table does exactly this — DreamStream 11.78 @1920×1080 next to
   DriveArena 41.80 @400×224 next to MetaDrive 175.53 @1600×900 — and their doc says as
   much: *"agents resize internally … no manual resize is needed — but low resolution
   measurably hurts scores"*.

   The policy metrics make this concrete: the agents resize internally anyway (rap and
   sparsedrive are handed an explicit `image_resize_hw=[1080,1920]`), so scoring a
   downsampled NuRec would measure a handicap NavSafe does not ship. On the pilot the
   same renderer scored FDπᵏ **4.87 at 1920×1080 and 19.31 at 400×224**.

   What is *not* allowed is a **downsampled** render standing in for a native one: FID
   builds its ground truth by resizing the original to the render's resolution, so a
   downsampled render would share a PIL BICUBIC resampling kernel with the reference it
   is scored against — free credit a natively-400×224 generator never gets. Both sides
   here are native, so the question does not arise.

3. **Same ground truth.** Same token, same resize, same GT cache.
4. **Same conditions.** Both are log replay: real ego trajectory, real 3D boxes, real
   map. Neither renderer is asked to invent geometry the other was given.
5. **Equal coverage, asserted.** `score.py` reduces both sides to the frames they *both*
   produced and then **asserts the symlink farms have identical counts**. An unequal
   count is a hard error — that is exactly the failure mode that would void the
   comparison silently.

## Run order

```sh
# manifest is already built; rebuild only if the corpus changes
kubectl exec -n cogrob horuan-nexussim -- \
  bash -lc 'conda run -p /avl-west/drivearena_bench/envs/ue python3 \
            /avl-west/render_quality_eval/build_manifest.py'

./submit_stage.sh infos          # once, CPU, ~20 min: nuPlan ann_file for 118 logs
./submit_stage.sh render_native  # NuRec 1920x1080 — NavSafe's real policy input
./submit_stage.sh drivearena     # WorldDreamer 400x224 — 40 jobs x 10 scenarios, ~85 min
./submit_stage.sh score          # FID + FVD on the intersection
./submit_fdpik.sh                # FDpi^k, one job per (agent x variation)

./status.sh                      # jobs, pods, progress against the manifest
./clean.sh                       # drop finished jobs so they release pod quota
```

Every stage is idempotent — a re-run submits only what is still missing, so a preempted
shard costs at most the unit in flight.

## Sharding

`render_native` shards by **clip** (4 per scenario, ~70 s each, independent).
`drivearena` shards by **scenario and never within one**: generation is autoregressive,
each frame conditioned on the previous generated frame, and the reference re-anchors on
the real image at a scenario boundary. Splitting a scenario across jobs would change its
output.

Conventions follow `navsafe_5s_500/submit_stage.sh`:

* one job per shard looping over its work — **not** an indexed Job;
* shard names carry a run id, because a Job's `spec.template` is immutable and reusing a
  name makes `kubectl apply` fail with "field is immutable";
* the done-check runs through `kubectl exec` (the Mac cannot read CephFS) and prints a
  sentinel, so an empty glob on the first run is distinguished from a dead pod — only
  the latter blocks a submission;
* in-flight work is read out of the live jobs' specs, not local files: `rendered/` sits
  under an iCloud-synced folder that renames on conflict, which silently made
  inflight=0 and double-assigned work;
* `JOBS` defaults to 40 to match the cards, still clamped to the namespace pod quota.

Node affinity, tolerations and image match `nautilus/pods/horuan-nexussim.yaml`:
us-west, RTX-3090, `ry-gpu-{05,06,07,08,11,12}`, toleration `nautilus.io/reservation=cogrob`.

## Files

| | |
|---|---|
| `build_manifest.py` | pins the frame set (run once, on the pod) |
| `prep_infos_inputs.py` / `merge_infos.py` | split yaml, time windows, local db staging |
| `make_shard_infos.py` | per-shard nuPlan infos + token map for DriveArena |
| `score.py` | intersect, assert equal counts, FID + FVD |
| `submit_stage.sh` / `submit_fdpik.sh` / `status.sh` / `clean.sh` | |
| `templates/*.yaml` | one per stage |

The scoring environment (both conda envs, `unified_evaluator` with its five policy
checkpoints, the FID/FVD scripts) lives in `/avl-west/drivearena_bench/` — see that
directory's README for the six upstream bugs that had to be patched to get any of this
to run.
