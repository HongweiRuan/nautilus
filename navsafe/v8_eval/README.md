# NavSafe V-8 completion jobs

This manifest runs the only V-8 cells that had no valid scored artifact after auditing `metrics_all` and all established output roots: DriveVLA-W0, SimWAM base, SimWAM-RL for seeds 0/1/1024, plus one SparseDriveV2 seed1024 retry.

The three seeds each use four 3-GPU workers (36 GPUs); the SparseDriveV2 retry uses 2 GPUs, for 38 GPUs total.

The worker is derived from `navsafe-v8a-cfg` at submission time. The only code additions are the already-proven DriveVLA dependency install and its extra environment cleanup, copied from the current offset-eval worker. All runs use NexusSim commit `649ddde`, the explicit V-8 recipes, numeric-score resume validation, and `/avl-west/navsafe_eval/v8_remaining` output.

Submit with `kubectl apply -f jobs.yaml`. After completion, validate scored JSON files and copy them into `/avl-west/navsafe_eval/metrics_all/<model>/<seed>/<token>.json`.
