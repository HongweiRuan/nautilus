# navsafe_421 — bulk navhard recon+eval pipeline (fire all 421 per stage)

Full NuRec pipeline for the **421 navhard scenes**, run one stage at a time but
**all 421 jobs at once** so every GPU is busy. No per-scene hardcoded yaml and no
serial orchestrator: a template per stage with `__SCENE__ __LOG__ __T0__ __T1__`
placeholders, plus a launcher that loops the manifest, plugs the values in, and
`kubectl apply`s the whole batch.

```
navsafe_421/
  scenes.tsv          # 421 rows:  token \t nuplan_log \t t0_us \t t1_us
  build_scenes.py     # regenerates scenes.tsv from the bridgesim navhard set
  run_stage.sh        # render + bulk-apply one stage for all 421
  status.sh           # complete/running/pending/failed counts for a stage
  templates/          # ncore aux arrow train export eval  (placeholder yamls)
  rendered/<stage>/   # materialized per-scene yamls (audit trail; regenerated)
```

## Stage order

```
ncore ─┬─> aux ──> train ──> export ──> eval
       └─> arrow ───────────────────────┘
```
- `ncore` builds the NCore store (`/avl-west/navhard421/<C>/clips/<C>/`).
- `aux` and `arrow` both depend only on `ncore` and can run concurrently.
- `train` needs `aux` (folds in the aux→manifest-base symlink itself).
- `export` needs `train`; `eval` needs `export` **and** `arrow`.

Each stage waits for the previous to finish — check with `status.sh`.

## Run it

```bash
cd navsafe_421
chmod +x run_stage.sh status.sh

./run_stage.sh ncore              # 421 CPU jobs
WATCH=1 ./status.sh ncore         # ...until complete=421

./run_stage.sh arrow              # 421 CPU jobs (independent; can start now)
./run_stage.sh aux                # 421 GPU jobs
WATCH=1 ./status.sh aux

./run_stage.sh train              # 421 GPU jobs (reserved 3090; queues to fit)
WATCH=1 ./status.sh train

./run_stage.sh export             # 421 GPU jobs
WATCH=1 ./status.sh export

WATCH=1 ./status.sh arrow         # make sure arrow finished too
./run_stage.sh eval               # 421 GPU jobs (self-contained serve+eval)
WATCH=1 ./status.sh eval
```

Outputs per scene under `/avl-west/navhard421/<token>/`:
`clips/` (ncore+aux), `arrow/`, `output_5cam/<token>/` (recon+ckpt),
`output_5cam/<token>/usd-out/*.usdz` (export), `eval/` (metrics + gif).

## Knobs (env vars on run_stage.sh)

| var | effect |
|---|---|
| `LIMIT=N` | render+apply only the first N scenes (smoke test) |
| `DRYRUN=1` | render into `rendered/<stage>/` but don't apply |
| `STAGGER=SEC` | apply one job every SEC instead of the whole dir at once — throttle to dodge the Nautilus util-policy burst cooldown if 421 simultaneous submits trip it |
| `TSV=path` | use a different manifest (e.g. a 20-scene subset) |

Re-running a stage is safe: `ncore`/`arrow`/`export` skip scenes whose output
already exists; `aux`/`train` have `backoffLimit:0` and are idempotent per token
(delete the job first to force a redo: `kubectl delete job -l app=navhard421,stage=<stage>,scene=<C>`).

## Failures

```bash
./status.sh <stage> failed        # list failed job names
kubectl logs -n cogrob job/navhard-<stage>-<token>
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
`[1633506278200211,1633506299700143]` window, all 421 resolved, 0 edge cases).

## Notes / conventions baked in (learned the hard way)

- **ncore/arrow ray cap**: `execution.threads_per_node=8` — big-core nodes else
  prestart ~256 ray workers that deadlock on the import storm.
- **train aux link**: `ncore-aux-data` writes `<scene>.aux.*`; NRE discovers
  `pai_<scene>.aux.*`. The train template creates the symlinks before training.
- **eval anchor**: re-referenced recons need `--nurec-work-dir` so the loader
  finds `nurec_origin_offset.json` and computes gaussian offset 0 (NOT the
  render-time `NUREC_GRPC_ORIGIN_OFFSET_FILE`, which double-shifts).
- **eval is self-contained** (serve-grpc + eval in one pod) so 421 run in
  parallel; a single shared serve deployment can't hold 421 recons.
- Train recipe = 3dgut_dynamic, 5 cameras, half-res (subsample=2). Edit
  `templates/train.yaml` for full-res / camera count / budget.
- Eval = DrivoR closed-loop, log_replay, 2s ego-replay warmup + 18s control.
  Adjust `--ego-replay-frames/--eval-frames` in `templates/eval.yaml`.
