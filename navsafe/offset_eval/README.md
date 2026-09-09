# Hand-off perturbation evaluation

One model × one scenario × one allowed offset × one seed is a cell. The ego is
perturbed once at the resolved hand-off frame. All cells preserve the original
replay prefix. This directory prepares full perturbation sweeps, not the recent
single-frame +1.5/+3/+5 m image requests.

## Directory structure

```text
config/
  campaign.json                 model registry, resources, workers, seed, code SHA
  models/<model>.tsv            one benchmark row per file
  scenarios/{all,plain,edit}.json
scripts/run_worker.sh           shared environment/renderer/eval implementation
templates/job.yaml            one Job template (never submit directly)
jobs/<model>/{plain,edit}/wXX.yaml
bin/manage.py                  render / stage / submit / status
bin/validate.py                local consistency and shell checks
bin/export_*.py                existing demo/BEV exporters (unchanged)
audit/                         cluster snapshot and configuration evidence
archive/20260909-flat-layout/   old flat layout, preserved for reference
```

Models are always at the same level, including `simwam` and
`diffusiondrive_simscale`. `plain` and `edit` are scenario partitions **inside
each model**. GPU needs are a separate resource profile in `campaign.json`;
there is no longer a `simwam` fleet beside `plain`/`edit`.

- **plain:** 46 scenarios without inserted actors, 869 allowed cells/model.
- **edit:** 8 scenarios with inserted actors, 152 allowed cells/model.
- Total: 54 scenarios, 1021 cells/model; C-8 has a restricted arm list.
- Grid: baseline; lateral and longitudinal ±0.5/1.0/1.5 m; yaw ±15/30/45°.

`all.json` is the reference union, not another launch partition. Workers split
sorted scenarios modulo `WORKERS`; each model/partition covers every cell once.
The checked-in defaults are eight plain workers and two edit workers per model.
Change these in the registry and render again before launching a new fleet.

## What has not run

The [2026-09-09 cluster audit](audit/README.md) found no output for these nine rows
in the hand-off campaign: `diffusiondrive_simscale`, `ltf`, `drivor`,
`sparsedrivev2`, `autovla`, `drivelaw`, `drivevla_w0`, `prioreye`, `rap`.
All nine have prepared Jobs (90 manifests). The full registry also provides
Jobs for the ten previously observed models (190 manifests total).

ResWorld has 220 existing cell directories, so it is **partially run**, not
missing. Existing directories/metrics are not a guarantee of successful scoring.
`simwam` means SimWAM-RL; `simwam_base` means the base checkpoint. These names
match the existing output layout and must not be silently renamed.

## Generate and validate (local only)

Requires Python 3 with PyYAML, Bash, and kubectl for cluster actions. No
`envsubst` is needed. Run from this directory:

```bash
python3 bin/manage.py render diffusiondrive_simscale
python3 bin/manage.py render --missing
python3 bin/validate.py
```

Generated manifests are reviewable ordinary YAML, with no unresolved shell
placeholders. Edit the registry/template/model files, then regenerate; do not
hand-edit generated Jobs. `--missing` uses the saved audit classification, not
an automatic live scan. `--all` explicitly selects all 19 rows.

## Stage and submit (only when ready to run)

This refactor did not stage or submit anything to the cluster. The new worker
uses a versioned tooling directory, leaving active legacy workers' files alone.
Staging requires an explicit pod/container that mounts `/avl-west`:

```bash
bin/stage.sh --pod horuan-nexussim --container nexussim-container
bin/submit.sh diffusiondrive_simscale                  # server dry-run only
bin/submit.sh diffusiondrive_simscale --apply           # create reviewed Jobs
# or select all nine rows absent in the saved snapshot:
bin/submit.sh --missing                                # server dry-run only
bin/submit.sh --missing --apply
bin/status.sh
```

Use `--partition plain` or `--partition edit` to select one partition. Bare
submission selects nothing and fails with usage guidance. Failures are surfaced;
there is no indefinite admission-retry loop. Submission uses `kubectl create`,
so an existing Job is not patched, restarted, or deleted. There is no automatic
cleanup of cluster resources. `bash_offset_eval.sh` forwards to this same entry
point; its arguments are model names, not old fleet names.

Staging refuses to overwrite its versioned destination and verifies SHA256 of
all files. For a changed release, choose a new `revision` and `tooling_root` in
`campaign.json`, regenerate, and stage it. Dry-run Jobs still require the
referenced Secrets/PVCs and cluster admission capacity when actually launched.

Do not run new and legacy workers over the same model/partition/output cells.
In particular, `navsafe-addon-w*` was still active during inspection. The nine
`--missing` models had no output in this campaign snapshot. Recheck if another
operator has started them since the audit.

## Resources and environment

- `shared-plain`: 1 GPU for plain (renderer cache 2), 2 GPUs for edit (cache 4).
  Used for the existing small models and DD+SimScale, which uses the same DD adapter.
- `dedicated`: 2 GPUs for both partitions; renderer on GPU 0, simulator/model on
  GPU 1. Also used conservatively for newly added models without verified
  shared-GPU memory measurements.
- `dedicated-vla`: DriveVLA-W0 uses 3 GPUs: renderer 0, simulator 1, model 2.
  Its tokenizer/Emu3 assets and additional VLA packages come from the working
  multi-model evaluation configuration.

Edited scenes must retain four loaded reconstructions: eviction loses injected
actors. SimWAM's extra GPU is a model memory requirement, not a scenario type.
DriveLaW installs its extra dependencies in an isolated side directory;
ResWorld checks its existing separate Python 3.8/MMCV environment rather than
trying to use the Python 3.12 VLA environment. SparseDriveV2 needs ninja and
Python development headers for its extension.

The existing allowed-node list and multi-GPU exclusion of `ry-gpu-08` are
preserved as configuration constraints, not asserted as current node health.
Requests equal limits for CPU/GPU; memory limits remain within 1.2× requests.
Jobs have a seven-day deadline and two retries. No new resource configuration
has been load-tested by this file-preparation task.

## DD + SimScale evaluation

It is an augmentation checkpoint of **`--model-type diffusiondrive`**:

```text
--checkpoint /avl-west/navsafe_eval/aug_zoo/SimScale/DiffusionDrive/diffusiondrive_sim_navhard.ckpt
```

`kmeans_navsim_traj_20.npy` must be beside the resolved checkpoint; both files
were verified on the cluster. The shared worker supplies the full command:
`eval_py123d.py --scenario-source py123d --render-backend nurec_grpc
--cam-height navsim --traffic-mode semi_reactive --controller lqr
--execution-mode controller --replan-rate 5 --camera-resolution-scale 1.0
--terminate-on-collision --eval-seed 0 --enable-vis
--vis-cameras CAM_L0,CAM_R0,CAM_B0`, plus scenario data, auto-selected recipe,
asset replacement manifest when present, resolved replay length, and each arm's
`--ego-perturb-lateral/longitudinal/yaw`. The scored horizon is scenario length
minus replay minus one, with the original minimum of 20 frames.

Code stays pinned to the existing perturb SHA `70a8d7ed`; this is not a migration
to the currently checked-out NexusSim revision. Overlay remains enabled to match
the campaign. Output is unchanged:

```text
/avl-west/runs/20260905-handoff-perturb-demo/eval/seed0/<leaf>/<token>/<arm>/<model>/
```

The original worker's resume rule requires its DONE log plus metrics and plan
records. Previously scored cells are skipped. The worker now returns nonzero
when any cells remain failed; a Kubernetes Completed status should not hide
failed cells. The existing demo exporters keep their historical model lists;
adding new rows to those presentation exports is separate from evaluating them.
