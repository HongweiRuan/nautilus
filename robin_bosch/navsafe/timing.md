# NavSafe eval speed: Robin's drivor_action (smoke, 2026-09-23)

Smoke job `robin-drivor-action-navsafe-smoke`, 1 worker (2x RTX 3090, ry-gpu-14), 2 scenarios x 4 models x seed 0,
NexusSim 649ddde, outputs in `/avl-west/navsafe_eval/robin_drivor_action_smoke`. 8/8 cells scored.

## Per cell

| scenario | model | cell wall | eval loop | frames | s/frame | overhead | driving_score | termination |
|---|---|---|---|---|---|---|---|---|
| 00185dab | dinov2_before | 14:51 * | 172 s | 61 | 2.82 * | ~12 min * | 11.05 | off_drivable |
| 00185dab | dinov2_after | 4:12 | 193 s | 114 | 1.69 | 59 s | 6.11 | contact_at_fault |
| 00185dab | best_before | 3:04 | 94 s | 56 | 1.67 | 90 s | 9.55 | off_drivable |
| 00185dab | best_after | 5:29 | 195 s | 114 | 1.71 | 134 s | 12.18 | contact_at_fault |
| 34ac200e | dinov2_before | 4:04 | 146 s | 88 | 1.66 | 98 s | 13.14 | off_drivable |
| 34ac200e | dinov2_after | 3:11 | 146 s | 89 | 1.64 | 45 s | 13.91 | off_drivable |
| 34ac200e | best_before | 5:22 | 201 s | 122 | 1.65 | 121 s | 9.99 | contact_at_fault |
| 34ac200e | best_after | 4:23 | 159 s | 97 | 1.64 | 104 s | 16.18 | off_drivable |

\* first cell of the pod: one-time warm-up (caches / JIT) inside the cell, not paid again.

- Steady state: **~1.65-1.7 s per frame** for all four models (95 %+ is rendering; the model barely matters).
- Fixed cost per cell (process start, scene load, model load): **~45-100 s** for the DINOv2 rows, **~90-135 s** for the
  GeoUP rows (6.3 GB encoder checkpoint). Average ~90 s.
- Pod bootstrap before the first cell: ~14 min (apt, venv, staging 6.6 GB of checkpoints, renderer start) plus the
  first cell's ~10 min warm-up.

## Full 280-scenario estimate (seed 0, 4 models = 1,120 cells)

Episode length drives the cost. Both smoke scenarios ended early (56-122 frames); over all 280 scenarios DrivoR
(`final_outputs/drivor/seed1`) averages **242 frames** (median 251, p90 401, cap 620). Assuming our models' episodes are
about as long:

per cell ~= 90 s + 242 x 1.67 s ~= **8.2 min** (range ~4 min for early terminations to ~19 min for a full 620 frames)

| GPUs | workers (2 GPUs each) | cells per worker | estimate |
|---|---|---|---|
| 8 | 4 | 280 | **~38 h** (range ~20-45 h) |
| 40 | 20 | 56 | ~8 h |

The low end is the case where our models terminate as early as in the smoke (~4.3 min per cell).
