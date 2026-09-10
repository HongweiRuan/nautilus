# NavSafe proxy verification results

Status: **baseline_holdout_pass**. Frozen selection: **172 / 280 scenarios**, 6 anchors per common leaf plus all 10 V-8 scenarios.

## Main result

The initial one-anchor-per-leaf design failed. The smallest development-passing candidate used 172 scenarios; a fresh five-model / three-family holdout then met the fixed gates. This is empirical baseline representativeness, not universal statistical significance and not yet perturbation-response validation.

| Check | DS | SR |
|---|---:|---:|
| Holdout MAE (pp) | 0.962 | 1.704 |
| Holdout maximum error (pp) | 1.357 | 3.333 |
| Holdout Spearman | 1.000 | 0.900 |
| Pairs >=10 pp apart reversed | 0.000 | 0.000 |

## Development iteration

| Scenarios | DS max error (pp) | SR max error (pp) | DS rho | SR rho | Pass |
|---:|---:|---:|---:|---:|---|
| 37 | 6.84 | 8.15 | 0.700 | 0.692 | False |
| 64 | 3.84 | 10.00 | 0.700 | 0.727 | False |
| 91 | 5.81 | 7.78 | 0.655 | 0.800 | False |
| 118 | 5.22 | 9.26 | 0.664 | 0.882 | False |
| 145 | 3.11 | 5.19 | 0.900 | 0.955 | False |
| 172 | 3.00 | 2.22 | 0.945 | 0.982 | True |
| 199 | 1.57 | 1.85 | 0.936 | 0.998 | True |

## Random baseline

1000 subsets, same per-leaf allocation; V-8 remains census in both.

| Metric | K-means MAE (pp) | Random median MAE (pp) | Random draws as good or better |
|---|---:|---:|---:|
| DS | 0.962 | 1.269 | 26.2% |
| SR | 1.704 | 1.753 | 47.7% |

K-means is NOT shown to significantly outperform stratified random sampling. This subset is 61.4% of the benchmark, so the savings are modest. Tight rankings among similar models make the original tiny subset unreliable.

## Repeated seed audit

| Model | Seed | Population | DS absolute error (pp) | SR absolute error (pp) |
|---|---|---:|---:|---:|
| drivor | 1024 | 280 | 1.038 | 1.071 |
| recogdrive_il | 1024 | 270 | 0.817 | 0.741 |
| recogdrive_rl | 1024 | 270 | 0.073 | 1.481 |
| simwam | 1024 | 270 | 0.570 | 0.370 |
| simwam_rl | 1024 | 270 | 1.063 | 1.111 |

These are the same trained policies on another seed, not independent models. See all_scores.json for every model, population denominator and missing-anchor status.

## Coverage and provenance

- All 28 leaves covered. Cluster memberships form an exact partition of all 280 tokens.
- Incomplete models are verified against their common 270-token population, not silently called full-280 results. V-8 is a 10-token census; only four learned models currently have its complete seed0 data.
- Four conflicting leaf labels were resolved using current bundle manifests, with source hashes in decision.json.
- Inserted-actor fraction: full 20.00%, weighted proxy 18.57%. This field is the stored manifest flag, not a separate visual audit.
- Weight concentration 1/sum(w^2) = 130.2; this does not establish independent samples.
- Some original runs used source-scope rendering workarounds. Two workaround tokens are selected anchors. Excluding them makes the frozen estimator undefined for their clusters; we therefore CANNOT certify robustness to their removal. No workaround is silently treated as a standard-render rerun.
- Related logs can induce scenario dependence. The result estimates this fixed benchmark; it does not establish generalization to all driving environments or confidence intervals based on 172 independent logs.

## Limits for perturbation experiments

**Not yet verified:** preservation of perturbed score changes, response curves, or ranking under perturbation. Baseline success does not imply this. A 54-token leaf-stratified non-proxy audit sample has been frozen separately in perturbation_audit_sample.json. It is a candidate audit set, not an evaluated validation set.

No GPU Job was needed or submitted for the completed verification. To validate perturbation response, the fixed proxy and a probability-sampled complement need paired baseline/perturbation outcomes from the same harness. GPU run configuration and approval must precede any such submission.

## Reproducibility

- Execution: cogrob / horuan-nexussim / nexussim-container, /hugsim-storage/NexusSim, conda base plus /root/nexussim-venv/bin/python. CPU only.
- snapshot.py: reads source JSON in parallel and records SHA256. snapshot.json is the immutable analysis input.
- select.py: selection, development folds, frozen holdout, random comparisons and seed audit.
- checks.py: nine invariants including holdout score-mutation leakage check and exact census reconstruction.
- A 1e-12 tolerance corrects rho=0.8999999999999998 at the mathematical 0.90 boundary. decision_pre_float_fix.json preserves the original classification; frozen tokens are byte-identical.
- The fixed gates (MAE<=3 pp, maximum<=5 pp, rho>=0.90, no reversal for >=10 pp pairs) are project choices, not literature guarantees.

## Literature

tinyBenchmarks (ICML 2024), §3.2: historical model-performance vectors, k-means, nearest observed example, cluster-size weights; §5: unseen-model evaluation and stratified random baselines. Our leaf constraints, family holdout, DS+SR features and precision gates are explicit adaptations. We do not claim to implement IRT++. https://arxiv.org/html/2402.14992v2

## Usage

Use proxy_set.csv and its weights, not an unweighted mean. weight_280 targets the 280-token benchmark; weight_270 targets the shared 270-token population. For a given leaf, normalize its cluster weights within that leaf. One leaf-level result remains a small diagnostic, not a guaranteed population estimate.
