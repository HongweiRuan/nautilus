# NavSafe model-zoo sweep on Nautilus

Evaluate every model in `/avl-west/navsafe_eval/model_zoo` closed-loop over the
127 scenarios in `/avl-west/navsafe_eval/dataset`, on the cogrob GPU
reservation, and land one directory of scores per model.

    ./check_adapters.sh          # is every row loadable? (submit refuses if not)
    ./submit_eval.sh             # SEEDS=1 WORKERS=30, drips the Jobs in
    ./status.sh                  # jobs, pods, cells done/failed/pending
    kubectl exec -n cogrob horuan-nexussim -- python3 /tmp/collect.py   # the table

## The shape of it

30 worker Jobs. Each is **one pod, one container, two RTX 3090s**: `serve-grpc`
renders on GPU 0, `eval_py123d.py` drives on GPU 1, and they talk over loopback.
Each worker owns a deterministic stride of the scenario list
(`tokens[index::30]`, 4–5 scenarios) and walks it **scenario-outer,
model-inner**, so the renderer keeps that scenario's four reconstructions
resident across the whole model list instead of reloading ~8 GB per model.

Why not the obvious alternatives:

| | |
|---|---|
| **`run_bundle_eval.sh`** | starts its renderer with `docker run`. A pod has no docker daemon, so the wrapper cannot run here at all. Every eval *flag* is copied from it verbatim — the flags are what make a score comparable. |
| **one Job per scenario** | pays ~15 min of venv build and 2–4 min of renderer start-up per scenario. Here both are paid once per pod and amortised over ~25 cells. |
| **a renderer Deployment per worker** | 30 Deployments is what gets an administrator's attention, needs a Service each, and lets a renderer outlive its client. Same pod, same script, no orphans. |
| **one Indexed Job, parallelism 30** | a Job per worker is independently resumable and independently replaceable: one broken worker can be re-submitted without touching the other 29. All 30 still go out in one pass — the util-policy webhook reacts to a burst only after the fact, and never touches a Job that already exists. |
| **a shared venv on the PVC** | not ours to create. The venv is rebuilt on each pod's own ephemeral `/root`. |

## When workers sit Pending

The reservation does not always have 30 free GPU pairs. Workers that do not
schedule stay Pending and start as the running ones exit — correct, but it puts
their slices in a serial tail, because the stride is fixed by `WORKERS` and only
that worker index will ever run those scenarios.

Do not fight the scheduler for it (on 2026-08-25 five workers stayed Pending with
13 GPUs apparently free in this namespace; dropping `ephemeral-storage` from
100Gi to 50Gi changed nothing, and the scheduler's own reason is unreadable —
the event message is capped at 1024 characters and spent on other nodes' taints,
and this account cannot list pods cluster-wide to see what other namespaces hold
on those nodes).

Redistribute instead, once the first wave is done:

    kubectl delete jobs -n cogrob -l app=navsafe-eval
    WORKERS=<however many actually scheduled> ./submit_eval.sh

Every finished cell is skipped, so this costs one venv build per pod and hands
the remaining scenarios to the workers that can actually run. It is safe at any
moment — including while workers are running, if you are willing to lose their
in-flight cells.

## Output layout

    /avl-west/navsafe_eval/outputs/
    ├── campaign.yaml                       git sha, flags, seeds, scenario count
    └── <model>/seed<N>/
        ├── <token>/navsafe_metrics.json    the score
        ├── <token>/vehicle_states.npy      the executed trajectory
        ├── <token>.log                     the episode log (sibling, not inside)
        └── <token>.serve.log               renderer tail, kept only on failure

A cell is **done** when its log carries `[eval_py123d] DONE.` *and* a
`navsafe_metrics.json` exists. Not a frame count: `--enable-vis` is off, so no
run writes frames — finished or not. Re-running `submit_eval.sh` skips every
done cell, so a worker that died for any reason resumes rather than restarts.

A worker's pod is **not** time-capped. The 6 h `activeDeadlineSeconds` cogrob
injects lands on bare Pods (the `horuan-nexussim` dev pod has it); a pod owned by
a Job does not get it — verified on this fleet's own pods. So a worker runs its
whole slice in one pod and the venv is built once, not once per 6 h.

## Episode shape

Copied from `run_bundle_eval.sh` policy mode, which is the reference for these
bundles:

    --traffic-mode semi_reactive --ego-replay-frames 20 --terminate-on-collision
    --execution-mode controller --controller lqr --replan-rate 5
    --camera-resolution-scale 1.0 --eval-frames 600 --navsafe-prune-artifacts
    (no --enable-vis)

`--eval-frames 600` is the same bound the wrapper gets implicitly, written down.
`eval_frames` counts SCORED frames, so the episode runs
`ego_replay_frames + eval_frames = 620` frames; unset, the evaluator stops at
`ego_replay_frames + SAFETY_CEILING_S / sim_dt = 20 + 60.0/0.1`, also 620. An
episode still normally ends earlier, on a taxonomy event (goal, contact,
off-drivable, deadlock) — of the six calibration cells the longest was 415
frames.

Renderer: `--cache-size 4 --enable-harmonizer --enable-editing-actors --renderer
default`. All three are load-bearing. `--cache-size 4` is a correctness floor —
a scenario is four 5 s reconstructions rendered in turn, and a smaller cache
evicts them mid-episode. `--enable-editing-actors` is not only for inserted
actors: every episode with background traffic sends actor poses as DynamicObject
updates, and a server without the flag refuses the whole request.

Seeds are `--eval-seed 1|2|3`. That reseeds python/numpy/torch only, so for a
strictly deterministic policy the runs are meant to be identical; in a 200-frame
closed loop, non-deterministic GPU kernels usually make them diverge anyway, so
treat the three as repeats rather than as a designed randomisation.

## What is not in this sweep

Eight benchmark rows — ReCogDrive ×2, MTDrive ×2, AutoVLA, SimWAM ×2, DriveLaW —
run their VLM or video model in a **subprocess under a separate venv**
(`NAVSAFE_VLA_PYTHON`). None of that exists on any storage this cluster mounts:

- the VLA venv (py3.12 / torch 2.10 cu128 / transformers 4.57.6) — its recorded
  location, `/bigdata/guest_zhihao/navsafe_venvs/vla`, is a collaborator's machine;
- upstream clones of **AutoVLA**, **DriveLaW** and **SimWAM** (weights alone are
  not enough — the repos supply the class definitions);
- `drivelaw/inference_front.yaml`, still an unmaterialised template.

Present and usable once the above exists: the server scripts
(`nexussim/modelzoo/navsim/vla_server/`), the zoo's `_base/qwen2.5-vl-3b-instruct`
and `_base/diffsynth`, and `recogdrive/vlm2b`. Note those adapters also pin their
server to `NAVSAFE_VLA_GPU` (default 7) — a **third** GPU per worker.

Adding a row back: put it in `models.tsv`; `check_adapters.py` already reports
the missing venv rather than letting 30 pods discover it at once.
