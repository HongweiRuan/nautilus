# navhard 421-scene batch orchestrator

Drives every scene in `navhard_scenes.tsv` through the 6-stage recon+eval pipeline
and stores every artifact under `/avl-west/navsafe/`, fully unattended.

```
convert ─┬─> aux ──> train ──> export ─┬─> eval
         └─> arrow ───────────────────┘
```

## Storage layout (`/avl-west/navsafe/`)
| layer1 | written by | key artifact (= "stage done" marker) |
|--------|-----------|----------------------------------------|
| `ncore/<tok>/clips/<tok>/`   | convert | `pai_<tok>.json` + 8 cam + lidar shards; aux writes `<tok>.aux.*` here |
| `arrow/logs/nuplan_test/<tok>/` + `arrow/maps/` | arrow | `*.arrow` |
| `training/<tok>/<tok>/`      | train  | `checkpoints/last.ckpt` |
| `export/<tok>/usd-out/`      | export | `*.usdz` (what serve-grpc serves) |
| `eval/<tok>/out/`            | eval   | `metrics.json` + gifs |
| `tools/`  | setup | `nuplan-conv-venv/` (persisted), `orchestrate.py`, `templates/`, `scripts/` |
| `state/`  | controller | `attempts.json` (retry bookkeeping) |

## Design: filesystem-as-state
A stage is **done** iff its artifact exists on the PVC — no external DB. The
controller (`orchestrate.py`) is idempotent + resumable: kill it anytime, re-run,
it resumes from whatever artifacts are present. Running Jobs are the "in-flight"
state (labels `batch=navsafe, stage=<stage>`). Failed jobs are retried up to
`--max-attempts` (tracked in `state/attempts.json`), then marked stuck.

All stages run as **k8s Jobs** (no dev-pod dependency — that pod dies every ~6h):
- convert, arrow → CPU, `metabench` image; each job builds its own numpy<2 nuplan
  venv into container-local `/root/cv` (NFS venv ops are too slow to persist on the PVC).
- aux, train, export, eval → GPU, pinned to the **cogrob reserved nodes**
  (`kubernetes.io/hostname In [ry-gpu-04,06,07,11,12,13,14]`, skip slow 05).
- eval is **co-located serve+eval** on one 3090 (serve-grpc bg + DrivoR fg, ~6.7GB),
  serving only that scene's usdz.

## One-time setup
```bash
kubectl apply -f navsafe-util.yaml           # long-lived util pod (PVC access from the Mac)
# seed the PVC (convert script referenced by convert.yaml); arrow config already registered.
# (templates + orchestrate.py on the PVC are only needed for the in-cluster Deployment path;
#  the Mac-driven loop reads them locally.)
kubectl cp ../1-convert_nuplan10hz.py navsafe-util:/avl-west/navsafe/tools/scripts/ -n cogrob
```
convert/arrow build their numpy<2 nuplan venv inline (no PVC venv to pre-build).

## Run it
**Validate (from any host with kubeconfig; PVC checks via `navsafe-util`):**
```bash
python3 orchestrate.py --once --dry-run --max-scenes 2     # log only
python3 orchestrate.py --loop --max-scenes 2               # real 2-scene pilot
```
**Full autonomous run (in-cluster Deployment):** needs `controller-rbac.yaml`
applied by a cogrob admin (this user can't create Role/RoleBinding). Then:
```bash
kubectl apply -f controller-rbac.yaml        # admin
# set MAX_SCENES=421 in controller-deploy.yaml, then:
kubectl apply -f controller-deploy.yaml
kubectl logs -f deploy/navsafe-controller -n cogrob
```
Without an admin, run `orchestrate.py --loop` from a trusted always-on host.

## Files
| file | what |
|------|------|
| `orchestrate.py` | the controller (reconcile loop, filesystem-state) |
| `templates/{convert,aux,arrow,train,export,eval}.yaml` | per-stage Job templates (`__SCENE__/__LOG__/__T0__/__T1__`); convert/arrow build their venv inline |
| `navsafe-util.yaml` | long-lived CPU util pod (PVC access / probe target) |
| `arrow-dataset-navhard.yaml` | py123d-conversion dataset config (registered in the py123d config dir) |
| `controller-rbac.yaml` / `controller-deploy.yaml` | in-cluster autonomous controller (needs admin RBAC) |

## Caps
`--gpu-cap 28 --cpu-cap 10` (or `GPU_CAP`/`CPU_CAP` env). Submission priority drains
the pipeline (eval>export>train>aux, arrow>convert) so scenes finish rather than all
piling at convert. Over-submitting is self-regulating — extra Jobs pend for a GPU.
