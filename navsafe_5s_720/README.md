# navsafe_5s_720 — 720-scenario (72 types × 10) 4×5s recon pipeline

Same 5s recon pipeline as `navsafe_421_5s`, scaled to **72 nuPlan scenario types ×
10 scenarios = 720 scenarios**, each cut into **four exact 5 s clips (s1..s4) = 2880
clips**. Products land in `/avl-west/navsafe-5s-720/`, k8s label
`app=navsafe-5s-720`, job names `nav720-<stage>-<clip>`.

Scenarios are sourced **navhard-first, then navtest backfill**; a type that even all
of navtest can't fill to 10 is written to `short_types.txt` (those must be
self-generated later — **out of scope for this task; we only convert scenarios that
already exist in navhard/navtest**).

```
navsafe_5s_720/
  select_720.py        # STEP 0: pick the 720, resolve 20s windows  (RUN ON A POD)
  scenes_720.yaml      #   -> type -> [{token,log,t0,t1,source}]   (traceable, grouped)   [generated]
  scenes_720.tsv       #   -> token\tlog\tt0\tt1\ttype\tsource     (distinct; fed to submit)[generated]
  short_types.txt      #   -> types < 10 across all navtest        (update index.html)     [generated]
  submit_stage.sh      # STEPS 1-4: gap-check CephFS + submit up to 180 jobs of one stage
  templates/           # ncore | aux | arrow | train job yamls (placeholders __SCENE__ __LOG__ __T0__ __T1__)
  rendered/<stage>/    # materialized per-clip yamls (audit trail; regenerated each run)
```

---

## STEP 0 — select the 720 scenarios (run once, read-only)

`select_720.py` reads the nuPlan DB `scenario_tag` table for the type of every
navhard+navtest token (the navsim token *is* `hex(lidar_pc_token)`), resolves each
to its 20 s window from the navsim pkls, and picks 10 per type (navhard first). It
**submits nothing** — it only writes the three manifests.

It needs `/avl-west` + `/hugsim-storage`, so run it **inside a pod** (e.g.
`horuan-nexussim`), then copy the manifests back here:

```bash
kubectl cp select_720.py cogrob/horuan-nexussim:/tmp/select_720.py
kubectl exec cogrob/horuan-nexussim -- bash -lc 'OUTDIR=/tmp /root/nexussim-venv/bin/python /tmp/select_720.py'
kubectl cp cogrob/horuan-nexussim:/tmp/scenes_720.tsv  ./scenes_720.tsv
kubectl cp cogrob/horuan-nexussim:/tmp/scenes_720.yaml ./scenes_720.yaml
kubectl cp cogrob/horuan-nexussim:/tmp/short_types.txt ./short_types.txt
```

Selection knobs are constants at the top of `select_720.py`:
- `N_PER_TYPE = 10`
- `PREFER_UNIQUE = True` — each token used by only one type, so the 720 are distinct
  scenarios (nuPlan tokens are multi-typed; greedy rarest-type-first avoids
  starving small types). Set `False` to let a token serve several types.

**index.html for short types:** any type listed in `short_types.txt` has fewer than
10 real scenarios even across all of navtest — mark those in
`/hugsim-storage/navsafe-vail.github.io/index.html` as "needs generated scenes".
(Generation itself is a later task.)

---

## STEPS 1–4 — run the pipeline (submit 180 at a time, drain, repeat)

Order (each waits on the previous): **ncore → aux → arrow → train**
(arrow and aux both need only ncore; train needs aux).

`submit_stage.sh <stage>` finds the clips **missing that stage's CephFS output**,
renders their job yamls, and applies **up to `BATCH` (default 180)** at once. The
"what's already done" check runs via `kubectl exec` into a pod that mounts
`/avl-west` (the Mac can't read CephFS); the `kubectl apply` runs with **your local
kubectl / account** (that's the account the util-policy is scored against).

```bash
chmod +x submit_stage.sh select_720.py

# STAGE 1: ncore — repeat until it prints "missing=0"
./submit_stage.sh ncore
# ...wait for the 180 to finish, then re-run to submit the next 180:
./submit_stage.sh ncore

# STAGE 2/2b: aux and arrow (both depend only on ncore; can interleave)
./submit_stage.sh aux
./submit_stage.sh arrow

# STAGE 3: train (needs aux) — produces the usdz the eval serves
./submit_stage.sh train
```

Useful env vars:

| var | default | effect |
|---|---|---|
| `BATCH` | `180` | max jobs to apply per invocation |
| `POD` | `horuan-nexussim` | pod used for the CephFS "what's done" gap-check |
| `DRYRUN=1` | — | render `rendered/<stage>/*.yaml` but don't apply |
| `TSV` | `scenes_720.tsv` | scenario manifest |
| `NS` | `cogrob` | namespace |

**How the gap-check decides "done"** (per 5 s clip `<C>` under `/avl-west/navsafe-5s-720/<C>/`):
- ncore → `clips/<C>/pai_<C>.json`
- aux   → `clips/<C>/<C>.aux.*.zarr.itar`
- arrow → `arrow/logs/nuplan_test/<C>/` (non-empty)
- train → `output_5cam/<C>/artifacts/last.usdz`

Re-running any stage is safe and idempotent: finished clips are skipped, and clips
already Running/Pending are not resubmitted. Keep re-running a stage until it reports
`missing=0`, then move to the next stage.

## Status / troubleshooting

```bash
# counts for a stage
kubectl get pods -n cogrob -l app=navsafe-5s-720,stage=ncore --no-headers | awk '{print $3}' | sort | uniq -c
# a failed clip's log
kubectl logs -n cogrob job/nav720-<stage>-<clip>
```

Conventions carried over from `navsafe_421_5s` (learned the hard way): ncore/arrow
cap ray at `threads_per_node=8`; train copies the store to local `/tmp`, trains
car2sim_6cam_static (160k/5M, `checkpoint.artifact.mesh.ground.enabled=false`),
keeps only `last.usdz`; the eval serves `last.usdz` directly (no export stage).
