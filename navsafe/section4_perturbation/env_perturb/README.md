# Environment perturbation eval

16 model directories are prepared. The current launch target is `drivor`; no Job has been submitted. Run `./stage.sh POD eval`, then `./drivor/submit.sh --dry-run`, and only use `--submit` when ready. The single canonical DrivoR Job has 28 indexes; each index runs two event recipes sequentially (56 evals total) and does not automatically retry failed indexes. There is no per-cell timeout. C1/VRU and C2/lead-brake are retired.
