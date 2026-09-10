# NavSafe proxy verification protocol — 2026-09-09

This protocol is fixed before computing selection/validation scores. This is an adaptation of tinyBenchmarks (ICML 2024), section 3.2 correctness-vector k-means, nearest real example, cluster-size weights; section 5 evaluates on unseen models. https://arxiv.org/html/2402.14992v2 . It is NOT the paper's IRT++ method and its reported 2% error is not transferable to driving.

## Data and scope
- Snapshot existing metrics_all JSON with per-file SHA256; no simulator reruns and no GPU needed for baseline verification.
- Use seed0 only for selection. Exclude PDM privileged reference from learned-policy clustering; evaluate separately.
- Reserve entire DrivoR, ReCogDrive (IL/RL), SimWAM (base/RL) families as final holdout. Never use their scores to select anchors, choose budget, or tune seeds. Models were chosen for family diversity, before score inspection.
- Development validation leaves one remaining model family out (all DiffusionDrive variants together; MTDrive SFT/mtGRPO together). Equalize each family's feature contribution; DS/100 and SR in [0,1] have equal weight. No z-score fit using holdout data.
- Benchmark union has 280 tokens; common coverage is 270. V-8 has only four seed0 models. Include all 10 V-8 tokens as a census stratum: no unsupported imputation or claim of a representative one-token V-8 anchor. Verify 270-token population for incomplete models and 280-token population only for complete models.
- Resolve four conflicting leaf labels from current dataset manifests, with provenance. Existing three source-scope rendering workarounds remain explicitly flagged; verification concerns supplied outcomes, not certification of evaluation-harness correctness. Report sensitivity excluding those three tokens.

## Selection and development iteration
- Within each of the 27 common leaves, k-means with k=1..7, capped by leaf size, random_state=20260909, n_init=20. Select the closest real example within each cluster; ties use token order. Split degenerate identical-feature groups deterministically if needed to retain the requested budget.
- Each anchor weight is cluster size / population size. V-8 census tokens have weight 1/280. Keep cluster membership so alternative denominators and leaf macro averages can be reconstructed.
- Choose the SMALLEST budget passing development leave-family-out gates: each metric MAE <=3 percentage points; each metric maximum absolute model error <=5 pp; Spearman >=0.90 for each metric; preserve the direction of all model pairs separated by >=10 pp. These are project precision goals, NOT literature-mandated thresholds.
- Do not choose the best random seed. If no budget passes, report failure rather than loosen gates. A large passing subset is a cost limitation, not a statistical innovation.

## Frozen-set verification
- Freeze tokens/weights using development models only and chosen k; evaluate the reserved families once. Same error/ranking/large-gap gates, with ties handled by Spearman's average ranks.
- Compare 1000 leaf-stratified random subsets at identical per-leaf budgets; report Monte Carlo percentile, not an invented hypothesis-test p-value.
- Report leaf coverage, weighted inserted-actor/source-type balance, per-leaf errors, and effective weight concentration 1/sum(w^2). Effective weight concentration is not proof of independent samples.
- Seed1024 is a supplementary same-policy robustness audit, not independent model validation. Missing cells explicitly excluded with denominators.
- No bootstrapping a single fixed anchor per leaf to claim sampling uncertainty. Existing finite-population errors are directly observable. Random-sampling distributions and held-out-family errors provide empirical evidence, not universal guarantees.

## Perturbation scope
Baseline agreement DOES NOT establish preservation of perturbation response curves. Before claiming that, freeze the proxy and run a separate probability-sampled non-proxy audit with paired baseline/perturbed runs. Report differences in score degradation and uncertainty. All image observations must use NuRec gRPC. Additional GPU Kubernetes Jobs require explicit user approval AFTER YAML/scripts and workload are reviewable; no jobs are submitted by this CPU pipeline.
