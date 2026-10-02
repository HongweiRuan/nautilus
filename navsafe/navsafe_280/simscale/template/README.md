# Reusable NavSafe full 280-scenario evaluation

This package uses one Kubernetes Indexed Job with 20 parallel workers (2 GPUs
each) over 280 unique scenarios.

To change models, edit `models.tsv`:

    label<TAB>model_type<TAB>checkpoint<TAB>extra_env

The label is the output directory name. Put comma-separated model-specific
environment assignments in `extra_env`. Change `OUTROOT`, seeds, worker count,
resources, dataset path, and common runtime settings in `job.yaml`.

Validate without submitting:

    python3 validate.py
    kubectl apply --dry-run=server -n cogrob -f job.yaml

Submit with `./submit.sh`. To intentionally replace the same named Job, use
`./submit.sh --replace`. The ConfigMap is built from local files at submission
time, so `job.yaml` stays small and reviewable.
