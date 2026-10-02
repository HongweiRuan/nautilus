# Table 9 result

Validated 20 unique warm-cache DrivoR episodes; all returned exit code 0, emitted the eval DONE marker, and produced scored metrics.

- Episode wall time: median 399.80 s, p90 712.63 s, maximum 953.25 s.
- Steady-state frame: per-episode median 1.7895 s, p90 2.5995 s, maximum 3.617 s; weighted mean 1.9601 s over 3,710 frames.
- Renderer startup: median 50.05 s, p90 50.06 s, maximum 50.06 s over 10 launches.
- Operational cell time (one startup added): median 7.5 min, p90 12.7 min, maximum 16.7 min.
- Combined GPU peak: median 24.15 GiB, p90 24.71 GiB, maximum 25.08 GiB; renderer median 19.69 GiB and policy-side median 4.53 GiB.
- Hardware: two NVIDIA GeForce RTX 3090 24 GiB GPUs per worker; GPU 0 renderer, GPU 1 policy/eval.
- NexusSim commit: 620ab1a27d209e46c76e818b6ea4fe30024d3d9b.
- Configuration: DrivoR baseline, semi_reactive traffic, seed 1, 20 ego-replay frames, up to 600 scored frames, visualization disabled.

The first submitted batch exposed a two-GPU warm-cache lookup bug: `nvidia-smi` returned the driver version twice, producing an invalid filename. The worker now selects the first line. Cold first episodes were excluded and rerun from the correct driver-keyed cache; the final sample contains 20 warm episodes.
