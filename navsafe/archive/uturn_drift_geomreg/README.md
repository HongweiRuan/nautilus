# uturn_drift_geomreg — does geometric regularization survive ego drift?

**Question.** Reconstructions of nuPlan scenarios look fine along the logged
trajectory, but a small lateral deviation makes the image collapse outright — not
blur, collapse. MTGS ([arXiv:2503.12552](https://arxiv.org/abs/2503.12552)) shows why:
in their ablation, dropping the depth loss leaves perceptual quality on training views
untouched (LPIPS 0.271 → 0.264) while geometry error explodes (AbsRel 0.078 → 0.891).
Training-view pixels cannot see a broken geometry. Only an off-trajectory view can.

MTGS's headline fix is multi-traversal, which we cannot do in NuRec. But half of their
recipe is single-traversal geometry regularization, and **NRE ships every one of those
terms already switched off**. Verified against a real trained config
(`/avl-west/navhard421/00c1e4eb4a045f20h1/output_5cam/*/config/parsed.yaml`):

| MTGS term | their weight | ours |
|---|---|---|
| surface-normal loss | λ=0.1 | `loss.normal.lambda_ = 0.0` |
| Gaussian flatten (anti-needle) | λ=1.0, r=10 | `loss.gaussian_flatten.lambda_ = 0.0` |
| camera-pose optimizer | lr 1e-4 → 5e-7 | `model.calib.enabled = false` |
| out-of-box loss | λ=1.0 | `loss.out_of_bound.lambda_ = 1.0` ✅ |
| per-camera colour correction | affine | `bilateral_grid_per_camera` ✅ |

**Scene.** `891953217984568c` — V-8 Illegal U-Turn, a 20 s host cut into four exact
5 s clips `…s1..s4`. A U-turn sweeps the camera through a wide arc of headings, so it
exercises off-trajectory geometry far harder than a straight drive. Baseline recons for
all four clips already exist under
`/avl-west/navsafe_5s_500/<clip>/output_5cam/<clip>/artifacts/last.usdz` and are **not**
retrained — they are the control arm.

## Arms

| arm | gaussians | overrides |
|---|---|---|
| `base` | 5M | *(nothing — the existing corpus recon)* |
| `geomreg` | 5M | `loss.normal.lambda_=0.1 loss.gaussian_flatten.lambda_=0.005` |
| `geomreg-calib` | 5M | the above + `model.calib.enabled=true` |
| `calib` | 5M | `model.calib.enabled=true` alone (only if `geomreg-calib` wins — tells the two effects apart) |
| `difix-probe` | 2M | 6k-step canary, difix on at step 3000 — one clip, ~15 min |
| `difix-2m` | 2M | `difix.training.enabled=true`, schedule rescaled to 160k steps |
| `base-2m` | 2M | *(nothing)* — tells "difix bought 3M gaussians" apart from "2M was always enough" |

### The difix question

`difix.training` renders the scene at ±3 m lateral offset each difix step and supervises
it against the Difix generative prior. It is the one lever that acts *directly* on the
views we otherwise cannot constrain, and the closest single-traversal stand-in for MTGS's
multi-traversal supervision. It does not fit next to 5M gaussians on a 24 GB 3090, hence
the 2M arms: **does 2M-with-difix beat 5M-without under drift?**

Two things had to be retuned:

- **Schedule.** NRE ships `start_step=20000`, `p_scheduler.milestones=[25000,28000]` —
  tuned for a 30k-step run. Ours is 160k, so the ratios (0.667 / 0.833 / 0.933) are held:
  `start_step=106000`, `milestones=[133000,149000]`.
- **Cache.** `difix.cache_dir=/avl-west/nre_cache/difix` on the PVC, so the checkpoint is
  fetched once rather than once per job. `difix-probe` warms it.

**Run `difix-probe` first.** Difix only engages at step 106000 in the real arm — about
3 h in — so an OOM or a composition failure (the trap that `fourier_features_dim` fell
into) would surface only after burning four GPUs for most of a run. The probe pulls difix
forward to step 3000 and answers three things in ~15 minutes: does it compose, what does
it cost in VRAM (every job now logs `[vram] … peak … MiB of 24576`), and is the
checkpoint cached for the real arms.

`gaussian_flatten` uses NRE's suggested λ=0.005 rather than MTGS's 1.0 because the two
are differently parameterized: NRE's `max_to_median_ratio_threshold` defaults to **1.0**
(penalize any anisotropy) against MTGS's **r=10** (penalize only needles), so NRE's
suggested weight is correspondingly smaller. If the arm under-performs, the threshold is
the second knob to try, not the weight.

Everything else in the training command is byte-identical to
`../navsafe_5s_500/templates/train.yaml`, so a quality delta is attributable to the arm.

## Layout

Ablation recons are experiment variants, so they go to a run dir, never into the corpus:

```
/avl-west/runs/20260819-uturn-drift-geomreg/
├── arm_check.py                       # copied up by submit.sh
└── recon/<arm>/<clip>/
    ├── artifacts/last.usdz
    └── config/parsed.yaml             # what the run actually parsed
```

Each job re-reads its own `parsed.yaml` at the end and fails if the arm's overrides did
not land, so no artifact can be compared under a label it does not have.

## Run it

```bash
DRYRUN=1 ./submit.sh                 # render into rendered/, apply nothing
./submit.sh difix-probe              # FIRST: 1 job, ~15 min — composes? VRAM? cache warm?
./submit.sh difix-2m base-2m         # then the difix question: 8 jobs, ~4.5 h each
./submit.sh                          # geomreg + geomreg-calib = 8 jobs, ~4.5 h each

kubectl get pods -n cogrob -l app=uturn_drift_geomreg
kubectl logs -n cogrob -l arm=geomreg,clip=891953217984568cs1 --tail=50
```

8 jobs × 1 GPU, pinned to the reserved 3090s (ry-gpu-05 excluded: measurably slower, and
one straggler holds up the comparison). Idempotent — a job whose `last.usdz` is already
on CephFS exits immediately, so a resubmit only picks up what is missing.

## Reading the result

The comparison is **not** on training views — those are exactly where the defect hides.
Render each arm at a lateral offset and compare there:

```
mode=val resume=<ckpt> dataset.val_sensor_transl_delta_m="[0,3,0]"
```

or run the normal closed-loop eval, where the planner's own deviation supplies the
drift.
