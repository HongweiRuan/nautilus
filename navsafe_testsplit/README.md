# navsafe_testsplit — scenario types mined straight from the nuPlan test split

Complements `navsafe_421_5s` / `navsafe_5s_720`. Those draw on NAVSIM's **navtest**,
which samples only 2 Hz keyframes and therefore covers just **55 of the 73** nuPlan
scenario types. The nuPlan DBs tag **all 20 Hz frames**, so mining `scenario_tag`
directly recovers types navtest's sampling missed (`changing_lane`,
`stopping_with_lead`, …).

Products go to `/avl-west/navsafe-testsplit/`, k8s label `app=navsafe-testsplit`,
job names `navts-<stage>-<clip>`.

```
navsafe_testsplit/
  mine_testsplit.py        # STEP 0: mine the test split      (RUN ON A POD)
  scenes_testsplit.tsv     #   -> 76 distinct scenarios; col 5 = every type it counts for  [generated]
  scenes_testsplit.yaml    #   -> grouped by type (traceable)                              [generated]
  coverage_report.txt      #   -> per type: navtest + mined + total                        [generated]
  taxonomy_73.txt          # canonical 73-type list (71 test-split + 2 trainval-only)
  submit_stage.sh          # STEPS 1-4: gap-check CephFS + submit up to 180 jobs of one stage
  templates/               # ncore | aux | arrow | train
  rendered/<stage>/        # materialized per-clip yamls (regenerated each run)
```

## Result

| | |
|---|---|
| recon-capable test-split logs | **147** of 1349 |
| mined scenarios | **76** (→ 304 clips at 4×5 s) |
| type-slots filled | **123** across 26 types (1.62 types per scenario) |
| combined with navtest's 441 | **517 scenarios**, **50 / 73** types complete at 10 |

## Two constraints that shaped the result

**Sensor blobs.** Recon needs real camera images. Only **147** of the 1349 test-split
logs have real dense (10 Hz, full-res) blobs under `nuplan-v1.1/sensor_blobs/`. The
other 1202 only have `rendered_sensor_blobs/` — the same frames at 2 Hz, re-compressed
(210 KB → 129 KB) — which would leave a 5 s clip with ~10 frames/camera instead of ~50
and give visibly worse 3DGS than every recon trained so far. Mining is therefore
restricted to the blob-backed logs (`REQUIRE_REAL_BLOBS = True`).

**One window, several types.** A tagged frame usually carries several tags, so one 20 s
window legitimately counts as a scenario for each type on its start frame. The selector
exploits this with a greedy **set cover** — each round takes the window that fills the
most still-needed types. That fills *more* types with *fewer* reconstructions (76
scenarios → 123 type-slots). Thinning of candidate start frames is **type-aware**:
thinning by time alone silently drops whole rare types, because the rare tag usually
sits on a skipped frame.

## STEP 0 — mine (read-only, already run)

```bash
kubectl cp mine_testsplit.py cogrob/horuan-nexussim:/tmp/mine_testsplit.py
kubectl cp ../navsafe_5s_720/scenes_720.tsv cogrob/horuan-nexussim:/tmp/scenes_720.tsv
kubectl exec cogrob/horuan-nexussim -- bash -lc \
  'OUTDIR=/tmp PRIOR_TSV=/tmp/scenes_720.tsv /root/nexussim-venv/bin/python /tmp/mine_testsplit.py'
kubectl cp cogrob/horuan-nexussim:/tmp/scenes_testsplit.tsv ./scenes_testsplit.tsv   # + .yaml, coverage_report.txt
```

Knobs at the top of `mine_testsplit.py`: `N_PER_TYPE=10`, `WINDOW_US=20s`,
`MAX_PER_LOG=3` (per type), `MAX_WINDOWS_PER_LOG=10`, `REQUIRE_REAL_BLOBS=True`.
`PRIOR_TSV` points at the navtest selection so only the **deficit** is mined;
`MINE_ALL=1` mines all 73 types to 10 regardless.

**Window** = `t0` at the tagged frame, `t1 = t0 + 20 s` exactly — the pipeline cuts it
into four exact 5 s clips. Windows never overlap each other or the navtest selection,
so nothing is reconstructed twice.

## STEPS 1–4 — run the pipeline (identical to navsafe_5s_720)

Order: **ncore → aux → arrow → train** (aux and arrow need only ncore; train needs aux).

```bash
cd navsafe_testsplit
./submit_stage.sh ncore     # submits up to 180 clips missing this stage; re-run until "missing=0"
./submit_stage.sh aux
./submit_stage.sh arrow
./submit_stage.sh train
```

`missing = 304 − done(CephFS) − (Running + Pending)`, so re-running never resubmits a
clip that is finished or already queued. Wait for a batch to drain before re-running,
or in-flight jobs just pile up (180 → 360 → …) and trip the util-policy burst cooldown.
Env: `BATCH=`, `POD=` (CephFS gap-check pod), `DRYRUN=1`, `TSV=`, `NS=`.

The `kubectl apply` runs with your local kubectl, so it is **your** account's
utilization the webhook scores.

## Website

`index.html` carries the combined coverage in the `#recon` section (regenerate with
`/tmp/add_recon_stats.py`): 517 scenarios, 50 types complete, 17 partial, 6 with none —
and the per-type table of what still has to be generated.
