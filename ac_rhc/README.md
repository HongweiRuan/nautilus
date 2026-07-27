# ac_rhc — Nautilus job manifests (namespace `cogrob`)

Every job submitted to Nautilus for the flowplanner-critic work lives here. Submit
with `kubectl apply -f <file>`; watch with `kubectl logs -n cogrob -f job/<name>`.
Repo/code + configs the jobs use are on CephFS at `/hugsim-storage/flowplanner-critic`.

## Collection + training (direct-Q: collect per-k replay → train-q + train-dq)

| manifest | job name | planner ckpt | sample_steps | k / target | node(s) | status |
|---|---|---|---|---|---|---|
| `horuan-directq123.yaml` | horuan-directq123 | diversity-50 | 4 | k=1/2/3, 100k/60k/45k | any reserved (5 GPU) | ✅ done |
| `horuan-directq-1020.yaml` | horuan-directq-1020 | diversity-50 | 4 | k=10/20, 20k/12k | ry-gpu-11 | ✅ done |
| `horuan-directq-4080.yaml` | horuan-directq-4080 | diversity-50 | 4 | k=40/80 | — | ✗ killed (I/O) |
| `horuan-dq-k80.yaml` | horuan-dq-k80 | diversity-50 | 4 | k=80, 2.5k (cut from 5k; 20h deadline was exceeded — /avl-west I/O + 80 sim-steps/tx) | ry-gpu-06 (5 GPU/18 CPU, 36h deadline) | ▶ running (retry) |
| **`horuan-dq-s15-k1.yaml`** | horuan-dq-s15-k1 | **base 400ep** | **15** | k=1, 15k | **ry-gpu-12** (4 GPU/16 CPU) | ▶ running |
| **`horuan-dq-s15-k5.yaml`** | horuan-dq-s15-k5 | **base 400ep** | **15** | k=5, 15k | **ry-gpu-06** (6 GPU/18 CPU) | ▶ running |
| **`horuan-dq-s15-k10.yaml`** | horuan-dq-s15-k10 | **base 400ep** | **15** | k=10, 8k (cut from 15k) | **ry-gpu-04** (7 GPU/22 CPU) | ▶ running |
| **`horuan-dq-s15-k20.yaml`** | horuan-dq-s15-k20 | **base 400ep** | **15** | k=20, 4k (cut from 15k) | **ry-gpu-13** (4 GPU/40 CPU) | ▶ running |

- diversity-50 runs → checkpoints `outputs/directq_div50/checkpoints/{q,dq}{k}.pt`, config `directq_diversity50_rng.yaml`.
- **s15 runs** → checkpoints `outputs/directq_base400_s15/checkpoints/{q,dq}{k}.pt`, config `directq_base400_s15_rng.yaml`
  (planner = original 400-epoch `model.pth` + patched `flow_planner_s15_model_config.yaml` with `sample_steps=15`).
- Longer-k jobs are pinned to higher-CPU nodes (collection is CPU/planner-bound; k=20→43-CPU node 13).
- One job per k so they run in parallel; each writes a distinct replay/checkpoint/`summary_{k}.json` — no collision.

## Evaluation (in `eval/`)

| manifest | what | deploy | status |
|---|---|---|---|
| `eval/eval-directq123.yaml` | q/dq {1,2,3} on val14 | exec=k, visible=k | ✅ done |
| `eval/eval-directq-hik.yaml` | q/dq {10,20,40,80} on val14 | exec=1, visible=k | ⏸ superseded by eval-dq1020 (40/80 never trained) |
| `eval/eval-dq1020.yaml` | q/dq {10,20} on val14 | exec=1, visible=k | ✅ done |
| `eval/eval-q20hf.yaml` | HF q20.pt (root of repo) on val14 | exec=1, visible=20 | ▶ running (ry-gpu-04) |
| `eval/eval-q40hf.yaml` | HF q40.pt (root of repo) on val14 | exec=1, visible=40 | ✅ done (0.8412 ≈ native) |
| `eval/eval-s15q{1,5,10,20}.yaml` | base400+s15 vanilla q{1,5,10,20} on val14 | exec=1, visible=k | ✅ done (0.856–0.865) |
| `eval/eval-s15b0.yaml` | base400+s15 B0 (candidate0, no critic) on val14 | exec=1 | ✅ done (**0.8805** — beats all s15 critics 0.856–0.865: critic hurts on this planner) |
| `eval/oracle-k10.yaml` | per-step best-of-N oracle ceiling, k=10 | — | ⏸ ready (run after collection frees /avl-west) |
| `eval/eval-{q1,q5,q10,q15,b0,fp-rollout}.yaml` | earlier AQC / native baselines | — | ✅ done |

## Notes / gotchas (learned the hard way)

- **`/avl-west` I/O is the collection bottleneck** — one 40-worker job already saturates it
  (workers go D-state). Parallel collection jobs share that fixed bandwidth; on the same
  storage they don't speed up. Prefer distinct nodes and/or stage dbs to node-local disk.
- **Interactive dev pod `horuan-flowplanner-critic` is deleted at the 6h limit.** Never host a
  long run on it; use a Job. For CephFS reads when it's gone, `kubectl exec` any running Job pod.
- **Known-flaky GPUs** (per-run, not permanent): ry-gpu-04 GPU1, ry-gpu-12 GPU4 — usable now.
- **Contended nodes** may reject 14+ CPU requests ("Insufficient cpu"); drop CPU or Ray CPW.
- Progress prints once **per collection round**; round 2 is large → long quiet gap, not a hang.
- CSV of all critic evals + submetrics: `python jobs/summarize_directq.py`.
