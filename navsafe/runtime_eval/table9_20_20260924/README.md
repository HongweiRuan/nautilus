# Table 9 runtime benchmark

- 20 fixed, evenly spaced valid NavSafe scenarios
- 10 workers, 2 RTX 3090 GPUs each; GPU 0 renderer, GPU 1 DrivoR
- DrivoR baseline, semi-reactive traffic, seed 1
- 20 replay frames plus at most 600 scored frames; visualization disabled
- warm Kit shader/material cache restored by driver-version key
- output: `/avl-west/navsafe_runtime/table9_drivor_20_20260924`

Submit with `./submit.sh`. After completion, run `python3 summarize.py` from a pod mounting `/avl-west`.
