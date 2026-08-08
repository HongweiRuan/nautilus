# navsafe_5s_500 — the final 500-scenario set, budgeted by taxonomy LEAF

Supersedes `navsafe_5s_720` and `navsafe_testsplit`, which were budgeted **per
scenario type** (10 × 73 types). The real target is **per taxonomy leaf**: 28 leaves,
every leaf ≥ 10 scenarios, **500 scenarios total**.

Products go to `/avl-west/navsafe_5s_500/`, label `app=navsafe_5s_500`, job names
`nav500-<stage>-<clip>`. Each scenario is a 20 s window cut into four exact 5 s clips.

```
navsafe_5s_500/
  select_500.py         # STEP 0: pick the 500 by leaf          (RUN ON A POD)
  scenes_500.tsv        #   token\tlog\tt0\tt1\ttypes\tleaves\tsource   [generated]
  scenes_500.yaml       #   leaf -> scenarios (traceable)                [generated]
  leaf_coverage.txt     #   per leaf: mined / to-generate / total        [generated]
  reuse_manifest.txt    #   clip ids carried over + which tree they came from
  migrate_artifacts.sh  # STEP 1: move existing artifacts into the new tree
  submit_stage.sh       # STEPS 2-5: gap-check CephFS + submit up to 180 jobs per stage
  templates/            # ncore | aux | arrow | train
```

## The budget

10 of the 28 leaves cannot be filled from logs and need **generated** episodes:

| reason | leaves |
|---|---|
| no nuPlan scenario_type at all | C-9 Single-Vehicle, C-10 Wrong-Way, V-10 Unsafe Merge, V-11 Driving Wrong Way, R-3 Micromobility, R-4 Animal, I-3 General Incident |
| type exists but is too scarce | C-7 Head-On (1 available), V-8 Illegal U-Turn (1), R-2 Bicycle (5) |

That reserves **93** scenarios for generation, so **500 − 93 = 407** are mined from
logs and spread over the 18 well-populated leaves (each far above the floor of 10).
Generation itself is **out of scope here** — this repo only converts what exists.

## Where the scenarios come from

navhard ⊂ navtest ⊂ the **147** test-split logs that ship real dense sensor blobs, so
all three sources are one pool: *every tagged frame in those 147 logs*. Mining is
restricted to them because recon needs real camera images — the other 1202 test-split
logs only have `rendered_sensor_blobs` (same frames at 2 Hz, re-compressed), too sparse
for 3DGS.

A frame carries several `scenario_tag` types, hence several leaves, so **one scenario
counts for every leaf it belongs to**. Budget is therefore counted in *distinct
scenarios*, never leaf-slots.

## Reuse — nothing is reconstructed twice

`/avl-west/navsafe-5s-720` already holds finished ncore (and aux) for the older
441-scenario selection. Carried-over scenarios keep their **exact token and t0**, so
their four clip ids `<token>s1..s4` are unchanged and the artifacts just move. The
selector drains the already-converted pool before mining anything new.

## Run it

```bash
# STEP 0 — select (read-only; already run, manifests are in this dir)
kubectl cp select_500.py  cogrob/horuan-nexussim:/tmp/
kubectl cp ../navsafe_5s_720/scenes_720.tsv cogrob/horuan-nexussim:/tmp/
kubectl exec cogrob/horuan-nexussim -- bash -lc \
  'OUTDIR=/tmp PRIOR_TSV=/tmp/scenes_720.tsv /root/nexussim-venv/bin/python /tmp/select_500.py'
kubectl cp cogrob/horuan-nexussim:/tmp/scenes_500.tsv ./scenes_500.tsv   # + .yaml, leaf_coverage.txt

# STEP 1 — move existing artifacts into the new tree (DRY RUN first)
kubectl cp scenes_500.tsv       cogrob/horuan-nexussim:/tmp/
kubectl cp migrate_artifacts.sh cogrob/horuan-nexussim:/tmp/
kubectl exec cogrob/horuan-nexussim -- bash /tmp/migrate_artifacts.sh            # reports only
kubectl exec cogrob/horuan-nexussim -- bash /tmp/migrate_artifacts.sh --apply    # really moves
#   COPY=1 copies instead of moving (keeps the old trees; needs 2x space)

# STEPS 2-5 — build what is still missing (ncore -> aux -> arrow -> train)
./submit_stage.sh ncore    # up to 180 clips per run; re-run until it prints missing=0
./submit_stage.sh aux
./submit_stage.sh arrow
./submit_stage.sh train
```

`missing = clips − done(CephFS) − (Running + Pending)`, so re-running never resubmits a
finished or queued clip. Wait for a batch to drain before re-running, or in-flight jobs
pile up (180 → 360 → …) and trip the util-policy burst cooldown. After STEP 1 the
gap-check already counts the migrated artifacts as done, so only the genuinely new
clips get built.

Env knobs: `BATCH=` (default 180), `POD=` (CephFS gap-check pod), `DRYRUN=1`, `TSV=`, `NS=`.
The `kubectl apply` runs with your local kubectl, so it is **your** account's
utilization the Nautilus webhook scores.

## Selector knobs (top of `select_500.py`)

`TOTAL=500`, `MIN_PER_LEAF=10`, `WINDOW_US=20s`, `MAX_PER_LOG=6` (per leaf, keeps one
drive from dominating a leaf), `PRIOR_TSV` (the reuse source), `SCAN_CACHE`
(`/tmp/scan_147.json` — the 147-log scan is the slow part and is cached).

## Leftovers

After migration, whatever remains in `/avl-west/navsafe-5s-720` and
`/avl-west/navsafe-testsplit` belongs to scenarios the 500 selection dropped.
`migrate_artifacts.sh --apply` reports how many are left; delete them by hand once the
new tree looks right.
