# tinyBenchmarks-style validation of the frozen proxy27

CPU-only recomputation from immutable per-scenario results. The 27 anchors and weights were NOT changed. No GPU or simulator execution.

## Literature mapping

tinyBenchmarks section 5 trains/selects on one group of models and estimates full benchmark scores on other models. It compares estimation errors against stratified random sampling and reports ranking correlation. We apply that validation protocol to the previously selected correctness-vector anchors. This is NOT IRT fitting, IRT++, or a replication of their numeric error guarantees. The paper also uses organization-based splits for HELM; our related model variants stay in the same held-out family.

Source: https://arxiv.org/html/2402.14992v2#S5

## Evaluation

- Population: 270 scenarios in 27 leaves, V-8 excluded.
- Fixed proxy: one anchor per leaf, cluster-size weights.
- Test models: DrivoR, ReCogDrive IL/RL, SimWAM base/RL. None formed the anchor feature vectors.
- Reference: exact mean over all 270 existing outcomes, not another sampled estimate.
- Comparator: 1000 random sets, each selecting one scenario per leaf, same weights.
- Seed1024 is a supplementary repeat-seed audit of the same models, not five additional independent models.

| Seed | Metric | Proxy MAE (pp) | Max error (pp) | Spearman | Random mean MAE (pp) | Random median MAE (pp) | Random sets no worse |
|---|---|---:|---:|---:|---:|---:|---:|
| seed0 | DS | 6.03 | 10.04 | 0.90 | 4.96 | 4.55 | 75.6% |
| seed0 | SR | 10.67 | 18.15 | 0.90 | 6.62 | 6.22 | 91.1% |
| seed1024 | DS | 4.63 | 5.79 | 0.90 | 4.87 | 4.39 | 54.9% |
| seed1024 | SR | 8.74 | 14.07 | 0.90 | 6.52 | 6.22 | 82.4% |

## Interpretation

The fixed 27-scene proxy does not demonstrate reliable absolute baseline score estimation or superiority to same-budget stratified random sampling. Ranking is partially retained. This does not test perturbation-response validity.

Do not label a 0.90 correlation as proof of representative absolute scores. This fixed subset is an exploratory diagnostic sample, not yet a validated replacement for the 270-scene benchmark. The paper does not prescribe a universal pass/fail cutoff for driving.

The same test families have been inspected in earlier iterations, so this is a retrospective evaluation, NOT a newly blinded test. There are only five policies in three families; the 1000 random draws do not increase the number of independent test models. Random-draw percentiles are sampling-comparator distributions, not confidence intervals for generalization to all driving tasks.

Existing source-run/renderer-workaround caveats apply. Verification is conditional on the supplied baseline outcomes. GPU testing would only be needed to evaluate new perturbation outcomes, not to compute the baseline evidence above.
