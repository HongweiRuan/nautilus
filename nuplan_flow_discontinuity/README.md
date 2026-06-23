# Flow Planner nuPlan replan-rate discontinuity eval

This mirrors the Diffusion Planner discontinuity eval, but wraps Flow Planner.

Files:

- `flow_planner/nuplan_simulation/planner/replan_rate_wrapper.py`: generic nuPlan planner wrapper. It only calls the base planner every `replan_interval_steps`, reuses the cached trajectory between replans, and logs boundary jumps to CSV.
- `flow_planner/nuplan_simulation/planner/replan_flow_planner.yaml`: Hydra planner config that wraps `flow_planner.planner.FlowPlanner`.
- `scripts/run_flow_nuplan_discontinuity_job.py`: indexed-job launcher. It maps `JOB_COMPLETION_INDEX` to `(replan_step, data_shard)`, builds a token/db shard manifest, and starts `run_simulation.py`.
- `flow_planner_model_config_nuplan.yaml`: checkpoint config with the missing `data.dataset.train` interpolation defaults added.
- `jobs/nuplan-flow-discontinuity-val14-job.yaml`: Nautilus indexed Job for Val14.

Replan steps:

- `1`: 0.1s, 10Hz baseline
- `2`: 0.2s, 5Hz
- `5`: 0.5s, 2Hz
- `10`: 1.0s, 1Hz
- `20`: 2.0s, 0.5Hz

Environment setup used in the pod/job:

```bash
source /opt/conda/etc/profile.d/conda.sh
conda create -y -n flow_planner python=3.9
conda activate flow_planner
python -m pip install --progress-bar off "pip<24.1"
cd /hugsim-storage/nuplan-devkit
python -m pip install --progress-bar off -e .
python -m pip install --progress-bar off -r requirements.txt
cd /hugsim-storage/Flow-Planner
python -m pip install --progress-bar off -e .
python -m pip install --progress-bar off -r requirements.txt
python -m pip install --progress-bar off "pytorch-lightning==2.0.1" "huggingface_hub==0.17.3" "fsspec==2023.3.0"
python -m pip check
```

Manual launch:

```bash
kubectl apply -f /Users/hongwei/Desktop/avl/nautilus/nuplan_flow_discontinuity/jobs/nuplan-flow-discontinuity-val14-job.yaml
```
