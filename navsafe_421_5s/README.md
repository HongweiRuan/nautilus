# navsafe_421_5s — 4×5s variant of the navhard recon+eval pipeline

Same pipeline as `navsafe_421`, but scoped to the **28 scenario-type scenes**
(one per navhard category, the webgif set) and each ~20s scenario cut into
**four ~5s segments (s1..s4)** instead of two ~10s halves (h1/h2) — so
**28 scenarios => 112 jobs per stage**. Products go to
`/avl-west/navhard421-website-5s/`, k8s label `app=navhard421-5s`, job names
`nav5s-<stage>-<clip>`.

Run one stage at a time but all 112 jobs at once so every GPU is busy. Template
per stage with `__SCENE__ __LOG__ __T0__ __T1__` placeholders; the launcher loops
the manifest, quarters each window, plugs the values in, and `kubectl apply`s.

```
navsafe_421_5s/
  scenes.tsv          # 28 rows:  base_token \t nuplan_log \t t0_us \t t1_us
  train_list.txt      # 112 clip ids (base_token + s1..s4) for submit_train.sh
  build_scenes.py     # (ref) regenerates the full 421 manifest from bridgesim
  run_stage.sh        # render + bulk-apply one stage; quarters each ~20s -> 4×5s
  status.sh           # complete/running/pending/failed counts for a stage
  templates/          # ncore aux arrow train export eval  (placeholder yamls)
  rendered/<stage>/   # materialized per-scene yamls (audit trail; regenerated)
```

## Stage order

```
ncore ─┬─> aux ──> train ──> export ──> eval
       └─> arrow ───────────────────────┘
```
- `ncore` builds the NCore store (`/avl-west/navhard421-website-5s/<C>/clips/<C>/`).
- `aux` and `arrow` both depend only on `ncore` and can run concurrently.
- `train` needs `aux` (folds in the aux→manifest-base symlink itself).
- `export` needs `train`; `eval` needs `export` **and** `arrow`.

Each stage waits for the previous to finish — check with `status.sh`.

## Run it

```bash
cd navsafe_421_5s
chmod +x run_stage.sh status.sh

./run_stage.sh ncore              # 112 CPU jobs
WATCH=1 ./status.sh ncore         # ...until complete=112

./run_stage.sh arrow              # 112 CPU jobs (independent; can start now)
./run_stage.sh aux                # 112 GPU jobs
WATCH=1 ./status.sh aux

./run_stage.sh train              # 112 GPU jobs (reserved 3090; queues to fit)
WATCH=1 ./status.sh train

./run_stage.sh export             # 112 GPU jobs
WATCH=1 ./status.sh export

WATCH=1 ./status.sh arrow         # make sure arrow finished too
./run_stage.sh eval               # 112 GPU jobs (self-contained serve+eval)
WATCH=1 ./status.sh eval
```

Outputs per scene under `/avl-west/navhard421-website-5s/<token>/`:
`clips/` (ncore+aux), `arrow/`, `output_5cam/<token>/` (recon+ckpt),
`output_5cam/<token>/usd-out/*.usdz` (export), `eval/` (metrics + gif).

## Knobs (env vars on run_stage.sh)

| var | effect |
|---|---|
| `LIMIT=N` | render+apply only the first N scenes (smoke test) |
| `DRYRUN=1` | render into `rendered/<stage>/` but don't apply |
| `STAGGER=SEC` | apply one job every SEC instead of the whole dir at once — throttle to dodge the Nautilus util-policy burst cooldown if 112 simultaneous submits trip it |
| `TSV=path` | use a different manifest (e.g. a 20-scene subset) |

Re-running a stage is safe: `ncore`/`arrow`/`export` skip scenes whose output
already exists; `aux`/`train` have `backoffLimit:0` and are idempotent per token
(delete the job first to force a redo: `kubectl delete job -l app=navhard421-5s,stage=<stage>,scene=<C>`).

## Failures

```bash
./status.sh <stage> failed        # list failed job names
kubectl logs -n cogrob job/nav5s-<stage>-<token>
# fix, then re-apply just that scene:
grep <token> scenes.tsv | while IFS=$'\t' read C L T0 T1; do
  sed -e "s|__SCENE__|$C|g" -e "s|__LOG__|$L|g" -e "s|__T0__|$T0|g" -e "s|__T1__|$T1|g" \
    templates/<stage>.yaml | kubectl apply -f - ; done
```

## Manifest provenance

`scenes.tsv` is the 421 bridgesim navhard scenes (`sd_<token>` dirs under
`/hugsim-storage/bridgesim_converter_navhard`) resolved to their native-10Hz
nuPlan `(log, t0_us, t1_us)` window, reproducing the openscene converter's
window (`num_history_frames=4`, `--num-future-frames-extract 40`) off the navsim
logs. `build_scenes.py` regenerates it (verified: 00c1e4eb → the known
`[1633506278200211,1633506299700143]` window, all 112 resolved, 0 edge cases).

## Notes / conventions baked in (learned the hard way)

- **ncore/arrow ray cap**: `execution.threads_per_node=8` — big-core nodes else
  prestart ~256 ray workers that deadlock on the import storm.
- **train aux link**: `ncore-aux-data` writes `<scene>.aux.*`; NRE discovers
  `pai_<scene>.aux.*`. The train template creates the symlinks before training.
- **eval anchor**: re-referenced recons need `--nurec-work-dir` so the loader
  finds `nurec_origin_offset.json` and computes gaussian offset 0 (NOT the
  render-time `NUREC_GRPC_ORIGIN_OFFSET_FILE`, which double-shifts).
- **eval is self-contained** (serve-grpc + eval in one pod) so 112 run in
  parallel; a single shared serve deployment can't hold 421 recons.
- Train recipe = car2sim_6cam_static, 5 cameras, 160k steps / 5M gaussians. Edit
  `templates/train.yaml` for full-res / camera count / budget.
- Eval = DrivoR closed-loop, log_replay, 2s ego-replay warmup + 18s control.
  Adjust `--ego-replay-frames/--eval-frames` in `templates/eval.yaml`.
