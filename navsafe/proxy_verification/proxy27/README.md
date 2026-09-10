# 27-scenario NavSafe proxy — V-8 excluded

Status: selection frozen; baseline diagnostics available; perturbation representativeness NOT validated.

## Selection

270 shared scenarios, 27 leaves; one representative per leaf. Within each leaf k-means k=1 is the feature centroid, and the nearest actual scenario is selected. Features are seed0 DS/100 and success across the same 11 development policies used previously, with equal contribution per policy family. This is performance-profile selection, NOT selecting high-SR scenes. No random seed search or budget expansion.

Source: tinyBenchmarks (ICML 2024), section 3.2, https://arxiv.org/html/2402.14992v2 . Leaf stratification and DS+SR/family weighting are our adaptations.

## Files

- proxy_set.csv: leaf, token, cluster size, weight.
- proxy_tokens.txt: exactly 27 tokens.
- proxy_set.json: each anchor and the original leaf members it represents.
- verification.json and baseline_scores.json: full diagnostic numbers.
- input_checks.json: 27/27 CPU directory/log-length checks. This is not a NuRec render test.
- select27.py: reproducible selection using the previous immutable snapshot.

## Baseline limitations

For the five policies not used to form the centroids:
- DS: MAE 6.03 pp, maximum error 10.04 pp, Spearman 0.90.
- SR: MAE 10.67 pp, maximum error 18.15 pp, Spearman 0.90.

These are retrospective diagnostics using the prior split, not a newly blinded confirmatory test. The 27-scene set does NOT pass the earlier tight baseline precision gates. Its budget is now fixed by the user for exploratory perturbation analysis; we do not lower those gates and rename it a success. One scene per leaf does not support within-leaf statistical generalization. Source-run/renderer-workaround caveats from the previous report still apply.

## Proposed GPU audit — NOT SUBMITTED

The proxy remains exactly 27. Separately draw 2 non-proxy scenarios per leaf (54 total) for a probability-sampled audit; audit54.json includes inclusion probabilities. These 54 are NOT added to the proxy.

27 proxy + 54 audit = 81 evaluated scenarios. Two models (DrivoR, DiffusionDrive-SimScale), baseline/+0.5m lateral, seed0: 324 episodes. Two Jobs, one active 2-GPU Pod per Job, maximum 4 GPUs. All observations use strict NuRec gRPC. Paired baseline and perturbation rerun at one pinned code version; do not mix old baseline runs with new perturbation runs.

Analyze proxy estimates against a stratified finite-population estimate using the sampled complement. Report uncertainty of that estimate. With only 2 audit scenes per leaf, intervals may be wide: an inconclusive result must not be called evidence of equivalence. This audit only covers these two models and this mild lateral arm, not every perturbation or environment change.

YAML files under gpu/ are suspended, not submitted. GPU runtime has NOT been tested. User confirmation is required before submission. The old 172-scenario/1120-episode proposal is superseded by this smaller proposal; its files are retained only as history.

## Selected scenarios

| Leaf | Token |
|---|---|
| C-1 | 02902d180b405100 |
| C-2 | f077a062ad9b55e9 |
| C-3 | 273f424fa2fc55ad |
| C-4 | 238f1cddb9415996 |
| C-5 | 58d69daf413c5d5a |
| C-6 | 0122ce98b2735558 |
| C-7 | 1e9350ac2bc25f59 |
| C-8 | 5ac972b34e2e5614 |
| C-9 | 6704953640e55b83 |
| C-10 | 2bd04a0902095129 |
| I-1 | 6fc91bf02f225d1b |
| I-2 | 0d5b8da00d505be0 |
| I-3 | 84acc78da95f56d3 |
| R-1 | 0027991369e05ab2 |
| R-2 | 20cc0fdb7e2d5c3f |
| R-3 | 132307b3c1a55f97 |
| R-4 | 225eb6e22af55972 |
| V-1 | 42af8e33480d53b3 |
| V-2 | 3d324bda0cec57ab |
| V-3 | c41f71c68ad45f21 |
| V-4 | 089e3eac4f7e5c5c |
| V-5 | 07c5114fdb395f8b |
| V-6 | 8661a7e9b4a95042 |
| V-7 | 26f4d8d4d72a588e |
| V-9 | 3a5278b27c87565f |
| V-10 | 63c145828c3b5fd8 |
| V-11 | 32d85d373126537e |
