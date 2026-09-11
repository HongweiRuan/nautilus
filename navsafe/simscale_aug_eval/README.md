# SimScale augmented NavSafe evaluation

The official SimScale model zoo publishes six NAVSIM-v2 `navhard` checkpoints. This campaign evaluates the five that are not already complete:

| Output slug | Planner | Backbone | Sim supervision | Official checkpoint |
|---|---|---|---|---|
| `ltf_simscale` | LTF | ResNet34 | pseudo-expert | `LTF/ltf_sim_navhard.ckpt` |
| `gtrs_dense_resnet_expert_simscale` | GTRS-Dense | ResNet34 | pseudo-expert | `GTRS_Dense/gtrs_dense_resnet_sim_expert_navhard.ckpt` |
| `gtrs_dense_resnet_reward_simscale` | GTRS-Dense | ResNet34 | rewards only | `GTRS_Dense/gtrs_dense_resnet_sim_reward_navhard.ckpt` |
| `gtrs_dense_vov_expert_simscale` | GTRS-Dense | V2-99 | pseudo-expert | `GTRS_Dense/gtrs_dense_vov_sim_expert_navhard.ckpt` |
| `gtrs_dense_vov_reward_simscale` | GTRS-Dense | V2-99 | rewards only | `GTRS_Dense/gtrs_dense_vov_sim_reward_navhard.ckpt` |

The official files are already downloaded under `/avl-west/navsafe_eval/aug_zoo/SimScale`, their SHA256 values were verified, and the SimScale source is pinned at commit `e7eb8a0ef3bcc41e86ccfdf4d0e5c9bb4a5826a1` with the 8,192-trajectory navhard vocabulary. `prepare-assets.yaml` is retained only for reproducibility. The GTRS adapter in this directory is injected only into each job's ephemeral NexusSim checkout. It uses the official GTRS model code and scoring equation; it does not alter `/hugsim-storage/NexusSim`.

`jobs.yaml` launches 20 workers with 2 RTX 3090 GPUs each: GPU 0 renders and GPU 1 runs the policy. Total requested capacity is 40 GPUs. Each worker takes a disjoint stride of the 280 scenarios and evaluates the five remaining models for seeds `0`, `1`, and `1024`. Results go to:

`/avl-west/navsafe_eval/simscale_aug_outputs/<model>/seed<seed>/<token>/`

The completed `diffusiondrive_simscale` and `drivor_simscale` evaluations are excluded from `models.tsv`, so this campaign does not spend GPU time rerunning them.

Prepare the authoritative 280-scenario dataset first. This creates an exact
`full_test/` view, reuses the 209 existing matching bundles, downloads the 71
missing official bundles (~560 GiB), and validates every manifest, Arrow tree,
and four-file NuRec reconstruction:

```bash
./prepare_full_test.sh
kubectl logs -n cogrob -f job/navsafe-full-test-prepare
```

After the preparation Job reports `READY: 280/280`, submit from this directory:

```bash
./submit.sh
```

`submit.sh` runs a shared-storage preflight and a Kubernetes server-side dry-run
before creating anything. It refuses to submit if the exact 280 bundles, pinned
nuPlan source, or Kubernetes schema validation is missing.

Monitor:

```bash
./status.sh
kubectl logs -n cogrob <pod> -c eval --tail=100
```

Final audit from the discovered `horuan-nexussim` utility pod:

```bash
kubectl exec -i -n cogrob horuan-nexussim -c nexussim-container -- python - < audit_outputs.py
```

The jobs are resumable. A cell is successful only when its log has the evaluator DONE marker and `navsafe_metrics.json` has `status: scored` with a numeric `metrics.driving_score`; excluded or null-score results are retried. GTRS-Dense imports the official nuPlan devkit pinned at commit `ce3c323af01c0d7ec5672f7832ef53f9c679aab0`.
