# Proxy-28: Robin best-PDMS before/after vs DrivoR

Columns are models. `best_before_*` / `best_after_*` = Robin's best-PDMS system before / after the safety-RL adapters; `_lqr` / `_pp` = LQR / pure-pursuit controller (this campaign, NexusSim 649ddde, seed 0).
`drivor_pp` = DrivoR, pure pursuit, this campaign. `hist_seed_0/1/1024` = DrivoR history from metrics_all, all LQR (seed 0/1024 = lqr_outputs 09-03; seed 1 = final_outputs 09-01, old LQR gains).
Full sub-metrics: `table.tsv` (one row per scenario x metric). BEVs: `bev/<token>.png`.

## Mean over the 28 scenarios

| metric | best_before_lqr | best_after_lqr | best_before_pp | best_after_pp | drivor_pp | hist_seed_0 | hist_seed_1 | hist_seed_1024 |
|---|---|---|---|---|---|---|---|---|
| DS | 58.96 | 58.36 | 73.82 | 71.28 | 66.85 | 68.52 | 73.47 | 68.52 |
| success % | 39.3 | 39.3 | 64.3 | 60.7 | 46.4 | 57.1 | 60.7 | 57.1 |
| RC % | 63.2 | 62.2 | 79.9 | 76.4 | 74.1 | 72.3 | 77.2 | 72.3 |
| NC | 0.998 | 0.997 | 0.995 | 0.997 | 0.997 | 0.997 | 0.995 | 0.997 |
| DAC | 0.967 | 0.967 | 0.990 | 0.986 | 0.987 | 0.984 | 0.990 | 0.984 |
| DDC | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 |
| TLC | 0.999 | 0.999 | 0.999 | 0.999 | 0.999 | 0.998 | 0.999 | 0.998 |
| TTC | 0.982 | 0.970 | 0.963 | 0.977 | 0.971 | 0.974 | 0.948 | 0.974 |
| LK | 0.765 | 0.763 | 0.726 | 0.697 | 0.726 | 0.732 | 0.708 | 0.732 |
| EP | 0.604 | 0.592 | 0.785 | 0.749 | 0.723 | 0.706 | 0.756 | 0.706 |
| EPDMS | 0.819 | 0.814 | 0.759 | 0.750 | 0.744 | 0.819 | 0.814 | 0.819 |
| off drivable (#) | 11 | 11 | 2 | 4 | 7 | 6 | 4 | 6 |
| collision (#) | 4 | 4 | 7 | 6 | 8 | 5 | 4 | 5 |
| goal reached (#) | 12 | 12 | 19 | 18 | 13 | 17 | 18 | 17 |

## Driving score per scenario

suffix: o = off drivable, c = at-fault contact, n = not-at-fault contact, ? = other (deadlock ...)

| token | leaf | recipe | best_before_lqr | best_after_lqr | best_before_pp | best_after_pp | drivor_pp | hist_seed_0 | hist_seed_1 | hist_seed_1024 |
|---|---|---|---|---|---|---|---|---|---|---|
| 0027991369e05ab2 | R-1 | - | 21o | 22o | 100 | 100 | 100 | 100 | 100 | 100 |
| 0122ce98b2735558 | C-6 | - | 41o | 42o | 100 | 100 | 100 | 100 | 100 | 100 |
| 02902d180b405100 | C-1 | - | 39c | 100 | 100 | 100 | 28o | 100 | 100 | 100 |
| 07c5114fdb395f8b | V-5 | - | 100 | 100 | 100 | 100 | 42c | 100 | 100 | 100 |
| 089e3eac4f7e5c5c | V-4 | - | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| 0d5b8da00d505be0 | I-2 | - | 100 | 100 | 100 | 100 | 89o | 100 | 100 | 100 |
| 132307b3c1a55f97 | R-3 | R-3 | 10o | 10o | 12c | 12c | 31c | 10o | 100 | 10o |
| 14c0a657ac3e5bb7 | V-8 | V-8 | 21o | 21o | 100 | 100 | 22c | 20c | 20c | 20c |
| 1e9350ac2bc25f59 | C-7 | C-7 | 21o | 21o | 100 | 21o | 100 | 21o | 42o | 21o |
| 20cc0fdb7e2d5c3f | R-2 | R-2 | 100 | 100 | 31c | 31c | 44o | 100 | 4c | 100 |
| 225eb6e22af55972 | R-4 | R-4 | 17c | 17c | 18c | 17c | 16c | 16c | 68o | 16c |
| 238f1cddb9415996 | C-4 | - | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| 273f424fa2fc55ad | C-3 | - | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| 2bd04a0902095129 | C-10 | C-10 | 22o | 22o | 55o | 47o | 32o | 23o | 30o | 23o |
| 32d85d373126537e | V-11 | V-11 | 21c | 20c | 14c | 15c | 34o | 11c | 9c | 11c |
| 3a5278b27c87565f | V-9 | - | 100 | 100 | 100 | 100 | 80o | 100 | 100 | 100 |
| 3d324bda0cec57ab | V-2 | - | 100 | 24c | 100 | 100 | 53c | 100 | 100 | 100 |
| 42af8e33480d53b3 | V-1 | - | 10o | 10o | 10o | 10o | 100 | 18o | 10o | 18o |
| 58d69daf413c5d5a | C-5 | - | 32o | 32o | 25c | 30o | 100 | 32o | 25? | 32o |
| 5ac972b34e2e5614 | C-8 | - | 64? | 64? | 100 | 100 | 100 | 100 | 100 | 100 |
| 63c145828c3b5fd8 | V-10 | V-10 | 74o | 70o | 100 | 100 | 100 | 23n | 100 | 23n |
| 6704953640e55b83 | C-9 | - | 14o | 14o | 100 | 100 | 100 | 100 | 100 | 100 |
| 6fc91bf02f225d1b | I-1 | - | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| 84acc78da95f56d3 | I-3 | I-3 | 14c | 14c | 14c | 23n | 14c | 14c | 14c | 14c |
| 8661a7e9b4a95042 | V-6 | - | 70 | 70 | 70 | 70 | 46c | 70 | 70 | 70 |
| 97dcc120f4695080 | V-7 | - | 100 | 100 | 100 | 100 | 25o | 100 | 100 | 100 |
| c41f71c68ad45f21 | V-3 | - | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| f077a062ad9b55e9 | C-2 | - | 60o | 60o | 18c | 20c | 17c | 60o | 64? | 60o |
