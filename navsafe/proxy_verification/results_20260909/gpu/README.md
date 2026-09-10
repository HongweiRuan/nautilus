# Optional GPU validation — NOT SUBMITTED

Purpose: verify whether the FROZEN 172-scenario proxy preserves the performance drop from baseline to a +0.5 m lateral handoff perturbation. Evaluate the full 280 scenarios for DrivoR and DiffusionDrive-SimScale; compare the weighted subset against the known full-population perturbed result and paired DS/SR degradation. This validates one mild lateral arm on two models, not the full perturbation grid or environment-reactivity experiments.

Budget: 280 scenarios x 2 models x 2 arms x 1 seed = 1120 episodes. Two Indexed Jobs; each has four sequential shards and one active Pod. Each Pod requests two GPUs, so maximum concurrent demand is four GPUs. Each Job has a seven-day deadline, no retries; each episode times out after 45 minutes. Those are safety limits, NOT predicted runtime. No GPU timing measurement has been performed for these selected cells.

YAML is suspended by default and nothing has been submitted. Before approved submission, change suspend to false in reviewed copies. User approval is required. Do not modify an existing conflicting Job. Local analysis and cluster file staging do not grant submission approval.

All 280 input bundles passed CPU existence/ego-log checks. This is not a GPU render or runtime smoke test. NuRec gRPC is the only render backend, with strict mode. Baseline and perturbation are rerun together at the same code SHA and settings: old baseline results are not silently combined with a new harness.

The worker is copied from offset_eval/scripts/run_worker.sh, with strict render mode explicitly set; legacy header comments describe its source campaign. Actual model/scenario/arm configuration comes from this directory. Original automatic recipe resolution and finite log horizon are preserved. Derived input preparation resolves recipe ego.replay_frames and selects complete Arrow copies; source paths and resolved counts are in selection.json.

Acceptance fixed before outcomes: for each model, proxy-versus-full absolute error <=5 pp for baseline and perturbed DS/SR, and <=5 pp for paired degradation in each metric. Report all errors, regardless of pass/fail. All 1120 cells must be scored before making a full-280 claim; infrastructure failures are not scored as zero or silently dropped. analyze_perturbation.py fails closed on missing/excluded cells. A failed audit must be disclosed; modifying selection using these outcomes makes this audit development data and requires another independent validation.
