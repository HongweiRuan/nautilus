# Per-scenario distribution campaign

27 fixed scenarios from the prior comparison, excluding V-8. Two models, seeds 0..29: 1,620 episodes. Indexed Job: 27 completions, 20 concurrent workers, 2 GPUs per worker. One scenario and 60 episodes per worker. No artificial noise or perturbation; deterministic seeds may overlap.

Frame 0 is the common local vehicle reference; no replay (explicit keep override for recipes). Run 40 steps at 0.1 s. State at 2 s is executed[19], at 4 s executed[39]. OL is the original logged ego position at each timestamp, not a model prediction. Preserve all raw artifacts for MC return extraction with gamma=0.99 and r=delta cumulative DS. Terminal horizon is 4 s, so G(4)=0; G(2) covers only the remaining rollout. Earlier benchmark termination is retained and flagged, never padded or replaced with invented points.

Recipe actors retain their original authored geometry/timing; forcing replay=0 changes takeover timing from the prior benchmark. Source is the pinned committed revision 31ff7e48922962f2f19f9b2b4bce79171eccac3a; no uncommitted changes are imported. Model checkpoints are recorded in models.tsv.

Outputs: /avl-west/navsafe_eval/heatmap/20260913_27x30_t0_4s/seed{0..29}/{leaf}/{token}/base/{model}/. Includes plan_records.json, vehicle_states.npy, driving_score_summary.csv, navsafe_metrics.json, and heatmap_episode.json. Finished episodes are audited for resolved handoff=0 and raw artifact presence. Missing 2s/4s states due to early termination are explicit in the audit. Figures and validated MC returns are generated after rollout artifacts are available; submission is not completion.
