# NavSafe Section 4 hazard reactivity full evaluation

This campaign evaluates 14 unique policies forming eight requested pairs on all 56 hazard recipes (28 scenarios x 2 hazards), seed 0. It records primitive reactivity data with `--record-reactivity-trace`, disables visualization, buffers the trace in memory, and writes one `reactivity_trace.zip` per cell at finalize.

One Indexed Job creates 22 workers at once. Each worker uses two RTX 3090 GPUs: GPU 0 holds the harmonized NuRec renderer (~21.8 GiB measured), and GPU 1 holds the evaluator/policy. This requests 44 GPUs total. The warm driver-keyed Omniverse Kit cache is restored before renderer startup.

Artifacts:

- `models.tsv`: 14 unique model configurations.
- `pairs.tsv`: the eight requested comparisons; repeated base models are evaluated once.
- `cells.json`: exactly 56 hazard cells.
- `runtime.tar.gz`: exact shared NexusSim working tree snapshot used by the campaign.
- `run_worker.sh`: finite, resumable worker without per-cell timeout or hidden retries.
- `audit_trace.py`: strict per-cell ZIP/storage/onset validator.
- `audit_outputs.py`: campaign completeness validator; success means 784/784 cells are scored and trace-valid.

Output root: `/avl-west/navsafe_eval/reactivity_hazard_outputs/20260913-v1`.

```bash
./submit.sh --dry-run
./submit.sh --submit
./status.sh
kubectl exec -n cogrob horuan-nexussim -c nexussim-container -- bash -lc \
  'python /avl-west/navsafe_eval/reactivity_hazard_eval/20260913-v1/audit_outputs.py'
```
