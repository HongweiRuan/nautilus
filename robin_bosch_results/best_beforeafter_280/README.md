# best_beforeafter_280

Robin bosch-summer `drivor_action` on the NavSafe full 280-scenario set, pure-pursuit controller, seed 0, NexusSim 649ddde, leaderboard scenario edits kept (`--recipe-dir benchmark`), no injected hazards.

Models: `drivor_action_best_before`, `drivor_action_best_after`. Raw outputs: `/avl-west/navsafe_eval/robin_drivor_action_full280/pure_pursuit/<model>/seed0/`. All 280 scenarios scored for every model. Renderer-crash scenarios re-run as on the leaderboard (metrics_all/README.md): 2391f12d7e6a5e7f with NAVSAFE_REPLACE_SCOPE=source; 442b2cf63c6f570a with NAVSAFE_REPLACE_SCOPE=source; 5d12ad55fdd858e1 with NAVSAFE_INSERT_CLASS_PER_SCENE=1; 9135a6d270475c7f with NAVSAFE_REPLACE_SCOPE=source. NAVSAFE_INSERT_CLASS_PER_SCENE=1 is a real fix (same conditions as the rest); NAVSAFE_REPLACE_SCOPE=source reduces asset-replace coverage, so those cells are not condition-identical - report them separately.

See `summary.md` for means and the per-scenario table, `table.tsv` for every sub-metric, `<model>/<token>.json` for each cell.
