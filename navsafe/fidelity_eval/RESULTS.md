# The eval pipeline's render quality: cause, fix, and the two metric sets
Run: /avl-west/fidelity_eval   Date: 2026-08-31

## 1. Why eval frames looked worse than `nre render`

Measured, not inferred. Laplacian variance on matched scene content, with NO
registration, so a pose offset cannot influence it:

| render path | Laplacian var | hi-freq share |
|---|---:|---:|
| offline `nre render` | 33.4 | 0.639 |
| **gRPC direct, harmonizer OFF** | **32.0** | 0.636 |
| eval pipeline, recon rig, harmonizer ON | 10.9 | 0.571 |
| eval pipeline, navsim rig, harmonizer ON | 14.2 | 0.570 |

The gRPC path matches the offline renderer. The DiffusionHarmonizer post-pass
is what costs the eval its detail.

Two hypotheses were tested and REFUTED first:

* **pose source** — the offline renderer's four `--calib-source` options
  (`training-rig-poses`, `-per-frame`, `training-sensor-poses-nocalib`,
  `-calib`) produce BYTE-IDENTICAL frames on these reconstructions (inf dB).
  The variable does not exist here; calib was evidently not enabled at
  training time and all four fall back to the same poses.
* **camera rig** — recon (10.9) and navsim (14.2) are both far below 32. The
  rig is not the cause of the softness, though it is a real difference in its
  own right (zeroed distortion, centred principal point, 1920x1120).

## 2. Fix

`serve-grpc --no-enable-harmonizer` (the server's own default; NavSafe's
worker scripts all override it on). A ready server is
`navsafe/fidelity_eval/templates/serve-grpc-noharm.yaml` — same pod as
production with its own name and Service, so both can run side by side. Point
an eval at `NUREC_GRPC_HOST=nurec-grpc-noharm`.

## 3. The two metric sets

Both rendered through the eval's own gRPC path, same 15,407 frames, same
1,467 FVD windows, same 4,138 FDpi^k tokens, same node/GPU/artifact per shard.
The ONLY variable is the harmonizer.

| eval configuration | FID ↓ | FVD ↓ | FDpi^k ↓ |
|---|---:|---:|---:|
| **harmonizer OFF** | **2.86** | **15.49** | 2.05 |
| harmonizer ON (what NavSafe runs today) | 3.21 | 22.17 | **2.01** |

For reference, the offline render on its own (larger) frame set: FID 2.50,
FVD 8.58, FDpi^k 1.88.

Per-policy FDpi (x100):

| configuration | DrivoR | DiffusionDrive | LTF | RAP | SDv2 | FDpi^k |
|---|---:|---:|---:|---:|---:|---:|
| harmonizer OFF | 2.74 | 3.50 | 0.83 | 1.83 | 1.37 | 2.05 |
| harmonizer ON | 2.13 | 4.06 | 0.88 | 1.46 | 1.50 | 2.01 |

Acceptance checks passed: `n_intersect` = 4138 on all ten cells;
`tr_sigma1` identical across the two configurations for every policy (so the
two rows normalize against the same original-feature distribution and are
directly subtractable).

## 4. Reading it

**The image metrics and the policy metric disagree, and the disagreement is
the finding.**

* FID +12% and FVD +43% with the harmonizer on. The much larger FVD penalty
  is consistent with the checkpoint's own name — `harmonizer_nontemporal.pt`.
  It repaints each frame independently, so temporal coherence degrades far
  more than single-frame appearance, and FVD is the metric that measures it.
* FDpi^k is 2.01 with the harmonizer vs 2.05 without — a 2% difference, well
  inside what the per-policy spread (DrivoR improves, DiffusionDrive worsens)
  suggests is noise. By the metric that reflects what a driving policy
  actually encodes, the harmonizer neither helps nor hurts.

So the harmonizer costs visible sharpness and temporal coherence while leaving
the policy-facing representation unchanged. Turning it off is a clear win for
the reported image metrics and, on this evidence, neutral for the policy.

Not measured: whether the harmonizer earns its keep on its stated purpose —
making an INSERTED asset sit in the scene's lighting instead of reading as a
pasted-on mesh (`nurec_serving/serve-grpc.yaml`). None of these frames carry
inserted actors, so this ablation cannot speak to that, and NavSafe's edited
scenarios are exactly where it would matter.

## 5. Coverage

* 15,407 of 16,707 manifest frames on BOTH configurations; the 408 missing are
  the same clips on both sides (gRPC render `ValueError`), so the comparison
  stays matched.
* The offline set covers 15,815, which is why its numbers sit on a slightly
  different frame set and are quoted only for reference.
