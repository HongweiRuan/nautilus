# Perturb coverage audit

Observed at 2026-09-09T04:55:51.861598+00:00 through cogrob/horuan-nexussim, container nexussim-container.

Output root: `/avl-west/runs/20260905-handoff-perturb-demo/eval/seed0`. Checked all 54 selected scenarios and all allowed arms (1021 cells/model).

Counts are file/directory existence, **not successful-evaluation counts**. Live workers can change these after this snapshot. Absence means no output observed in this campaign, not proof that a job was never submitted anywhere.

| Model | Cell directories | Offset directories | Metrics files | Plan files |
|---|---:|---:|---:|---:|
| autovla | 0 | 0 | 0 | 0 |
| diffusiondrive | 1011 | 957 | 1011 | 1011 |
| diffusiondrive_beyonddrive | 1011 | 957 | 1009 | 1010 |
| diffusiondrive_simscale | 0 | 0 | 0 | 0 |
| drivelaw | 0 | 0 | 0 | 0 |
| drivevla_w0 | 0 | 0 | 0 | 0 |
| drivor | 0 | 0 | 0 | 0 |
| ltf | 0 | 0 | 0 | 0 |
| mtdrive_mtgrpo | 769 | 721 | 766 | 766 |
| mtdrive_sft | 772 | 724 | 769 | 772 |
| pdm_closed | 1011 | 957 | 1009 | 1011 |
| prioreye | 0 | 0 | 0 | 0 |
| rap | 0 | 0 | 0 | 0 |
| recogdrive_il | 1021 | 967 | 1021 | 1021 |
| recogdrive_rl | 1011 | 957 | 1011 | 1011 |
| resworld | 220 | 195 | 216 | 219 |
| simwam | 1005 | 951 | 1002 | 1003 |
| simwam_base | 781 | 733 | 772 | 773 |
| sparsedrivev2 | 0 | 0 | 0 | 0 |

## Configuration evidence

- `rebecca_eval_scripts/rerun-w00.yaml` references ConfigMap `navsafe-rerun-cfg`. Its current model list contains only five rerun rows, not DD+SimScale.
- Full model rows: cluster ConfigMap `navsafe-recon-cfg`, cross-checked against `/avl-west/navsafe_eval/models_fill10.tsv`. Snapshot: `source-recon-models.tsv`.
- DriveVLA-W0 and ResWorld: `navsafe-s3-dvw0-cfg` and `navsafe-s3-rw-cfg` (model rows saved alongside this report; environment blocks incorporated into the shared worker).
- Existing perturb model lists supply `simwam` = SimWAM-RL and `simwam_base` = SimWAM, preserving output names.
- All 19 rows had existing checkpoint/config/environment paths at inspection; both DD augmentation checkpoints had sibling `kmeans_navsim_traj_20.npy`. This is a file-existence check, not a fresh inference run.
- Active legacy `navsafe-addon-w*` Jobs were observed; do not concurrently submit replacement MTDrive/SimWAM-base workers to the same output cells.
- Scope is the 19 configured benchmark variants; retired `transfuser` and `ego_status_mlp` are not reintroduced.

## Validation

- 190 generated manifests: 19 models × (8 plain workers + 2 edit workers).
- Nine never-observed models: 90 prepared Jobs. Jobs have not been submitted.
- Local validation checks exact template reproduction, unique names, typed env values, GPU mapping, resource ratios, and disjoint partition coverage.
- Shell syntax checks pass; no new GPU evaluation was launched for this refactor.

- Kubernetes client dry-run with schema validation accepted all 190 manifests. No server admission or GPU runtime check was performed.
