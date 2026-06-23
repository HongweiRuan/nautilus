# nuPlan replan-rate discontinuity evaluation

## Replan settings

The wrapper keeps nuPlan's simulation step unchanged. With the default nuPlan `0.1s` step:

| `replan_interval_steps` | interval | rate |
|---:|---:|---:|
| 1 | 0.1s | 10Hz baseline |
| 2 | 0.2s | 5Hz |
| 5 | 0.5s | 2Hz |
| 10 | 1.0s | 1Hz |
| 20 | 2.0s | 0.5Hz |

The Job YAML uses:

```text
REPLAN_STEPS=1,2,5,10,20
NUM_DATA_SHARDS=8
completions=40
```

Indexed Job mapping:

```text
rate_idx = JOB_COMPLETION_INDEX // NUM_DATA_SHARDS
data_shard_idx = JOB_COMPLETION_INDEX % NUM_DATA_SHARDS
```

Each pod requests 8x RTX 3090 and uses nuPlan Ray with:

```text
worker=ray_distributed
worker.threads_per_node=32
number_of_gpus_allocated_per_simulation=0.25
```

That is up to 32 concurrent simulation tasks per 8-GPU node, subject to GPU memory.

## Files installed into Diffusion-Planner

```text
diffusion_planner/planner/replan_rate_wrapper.py
diffusion_planner/config/planner/replan_diffusion_planner.yaml
scripts/run_nuplan_discontinuity_job.py
```

## Launch

```bash
kubectl apply -f /Users/hongwei/Desktop/avl/nautilus/nuplan_discontinuity/jobs/nuplan-discontinuity-val14-job.yaml
```

## Monitor

```bash
kubectl get jobs -n cogrob nuplan-discontinuity-val14
kubectl get pods -n cogrob -l k8s-app=nuplan-discontinuity-val14 -o wide
kubectl logs -n cogrob -l k8s-app=nuplan-discontinuity-val14 --tail=100 -f
```

## Outputs

nuPlan simulation outputs:

```text
/hugsim-storage/diffusion_planner_exp/exp/simulation/closed_loop_nonreactive_agents/diffusion_planner_discontinuity/...
```

Boundary discontinuity CSV files:

```text
/hugsim-storage/diffusion_planner_exp/discontinuity/val14/closed_loop_nonreactive_agents/replan_*/shard_*/*.csv
```

Shard manifests:

```text
/hugsim-storage/diffusion_planner_exp/shards/val14/8_shards/manifest.json
```
