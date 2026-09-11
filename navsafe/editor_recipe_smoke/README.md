# C-1 / C-2 edited-recipe DrivoR smoke test

## Submit

```bash
cd /Users/hongwei/Desktop/avl/nautilus/navsafe/editor_recipe_smoke
./submit.sh --dry-run
./submit.sh --submit
./status.sh
```

One indexed Job, two workers; each runs one scenario's three dangerous events sequentially. Six evaluations total, DrivoR only, seed 0, `--eval-frames 200`, `--enable-vis --vis-cameras CAM_L0,CAM_R0,CAM_B0`. Two GPUs per worker, renderer GPU 0/cache 4 and rollout GPU 1. There are no ego offsets. Baseline recipes are prepared but not evaluated in this smoke test. Creation fails if the Job name already exists; the script never deletes or restarts a Job.

## ZIP to runnable recipe

Cluster root: `/avl-west/navsafe_eval/editor_smoke/20260911-c1-c2-drivor-v1`.

1. Upload the two original ZIPs unchanged into `raw/`. Extract into separate `unpacked/<zip-name>/` directories after rejecting absolute/traversal paths. Keep original manifests, drafts and checks.
2. Read each event.yaml and baseline.yaml with the real `load_recipe(..., verify=True)` API. Exported JSON is already valid YAML; do not regenerate a trajectory from draft control points. The sampled `policy.path_polyline` is authoritative.
3. Keep actor source IDs, assets, onset, speed, braking parameters, poses, event/baseline enable flags, original path samples and the 20-frame replay unchanged. For vehicles, append one point collinear with the final segment if necessary. Target length is `(22 - onset_s) * speed + 5 * speed`: enough for replay + 200 scored frames, plus a five-second margin. This adds straight tail only, including a small reserve for C-1; it does not rerun the old spline generator. VRU paths remain unchanged and stop at their endpoints.
4. Serialize using `Recipe.to_yaml()` so the runtime recalculates each actor SHA256. Reload through `edits_from_recipe_file`, which verifies integrity and resolves the real asset/gait bank. Check all vehicle samples through 22 s for path exhaustion; original motion before the old endpoint is numerically unchanged. Files go to `recipes/<token>/<event>/{event,baseline}.yaml`. `preparation_report.json` records source/output SHA256 and exact added distances.
5. `cells.json` binds the six event recipes to C-1's `/avl-west/navsafe_eval/dataset/02902d180b405100/arrow` and C-2's `/avl-west/navsafe_dev/full_test_mirror/f077a062ad9b55e9/arrow` data. Pass `--recipe` explicitly and `--traffic-mode navsafe`: this avoids auto-selecting the old benchmark recipe and ensures authored actors move. Banks are `/avl-west/navsafe_eval/asset` and `/avl-west/navsafe_eval/gait_bank`.
6. `runtime.tar.gz` snapshots current cluster code, including uncommitted authored_path driver/registration. `runtime_provenance.json` records base commit, dirty state and archive hash. The older offset_eval commit does not contain this driver. Each fresh Job expands this snapshot onto local `/root/ns` and builds its environment there; active cluster code is never edited.

## Outputs and checks

`results/<leaf>/<token>/<event>/drivor/` contains eval.log, exit_code.txt, metrics, plan records and visualization images. `results/w0/` and `results/w1/` contain worker/renderer logs and summary.json. The worker fails if eval exits nonzero, lacks DONE, metrics/plans or visualization, or does not report loading the requested editor recipe. `check_inputs.py` revalidates all twelve inputs before GPU rollout. `summarize.py` can be rerun against the results directory.

The 200 limit counts scored frames; 20 replay frames are additional. Original logs are 201 and 200 frames, so the maximum horizon reaches beyond log coverage by about 2 s. This is the explicitly requested smoke-test cap, not a changed benchmark horizon. Collision/other termination may end a run earlier. Passing runtime checks proves the edit was loaded and artifacts produced; judge visible motion and whether the event occurred before termination from the saved frames before calling the scenario qualified. Cloud browser checks are not ground-truth qualification.

## Preparation status (2026-09-11)

All twelve recipe inputs passed cluster preflight. Kubernetes server dry-run was denied by `job.nrp-nautilus.io` because account pod resource utilization is too low. No Job was submitted and no evaluation ran. After that account-level restriction is resolved, use the commands above. Do not interpret input validation as successful rendered evaluation.
