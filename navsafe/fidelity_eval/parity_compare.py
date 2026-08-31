#!/usr/bin/env python3
"""Compare the offline and gRPC render paths frame by frame.

Decides whether the existing 15,815-frame offline render can stand as the
ablation's Base row. The harmonizer is a serve-grpc postprocess, so the
+Harmonizer row has to come from the gRPC path; if the two paths do not
already agree with the harmonizer OFF, then "Base vs +Harmonizer" would also
be "offline vs gRPC" and the ablation would not isolate the harmonizer.

Reports per clip: how many frames each side wrote, how many filenames match,
and on the shared frames the byte-identity rate and the PSNR distribution.
"""
import os, sys, glob, hashlib
import numpy as np
from PIL import Image

ROOT = "/avl-west/fidelity_eval/parity"
IDENTICAL_PSNR = 50.0     # above this the difference is jpeg noise, not content


def frames(d):
    """Ordered frame list for one clip.

    The two paths do NOT agree on filenames: the offline renderer is told
    `--frame-naming frame-end-timestamp` and writes <timestamp>.jpg, while
    render-grpc has no such option and writes a contiguous 000000.jpeg index.
    Both walk the SAME training trajectory in time order and emit the same
    count, so position after sorting is the pairing. Sorting is numeric on the
    filename stem, which is correct for both schemes (timestamps and indices
    are both monotonic integers) and avoids the lexicographic trap where
    '1632943463' sorts before '163294346'."""
    ps = glob.glob(os.path.join(d, "**", "*.jpg"), recursive=True) + \
         glob.glob(os.path.join(d, "**", "*.jpeg"), recursive=True)
    def key(p):
        stem = os.path.splitext(os.path.basename(p))[0]
        return (0, int(stem)) if stem.isdigit() else (1, stem)
    return sorted(ps, key=key)


def psnr(a, b):
    a = np.asarray(a, np.float64); b = np.asarray(b, np.float64)
    m = ((a - b) ** 2).mean()
    return float("inf") if m == 0 else 10 * np.log10(255.0 ** 2 / m)


clips = sorted(os.path.basename(p) for p in glob.glob(f"{ROOT}/offline/*"))
if not clips:
    sys.exit(f"no clips under {ROOT}/offline")

print(f"{'clip':<22}{'offline':>8}{'grpc':>7}{'shared':>8}{'identical':>10}"
      f"{'PSNR min':>10}{'PSNR med':>10}")
tot_shared = tot_ident = 0
all_psnr = []
for c in clips:
    off, grp = frames(f"{ROOT}/offline/{c}"), frames(f"{ROOT}/grpc_off/{c}")
    n_pair = min(len(off), len(grp))
    shared = list(range(n_pair))
    ps, ident = [], 0
    for i in shared:
        a, b = Image.open(off[i]).convert("RGB"), Image.open(grp[i]).convert("RGB")
        if a.size != b.size:
            # A size mismatch is itself a finding: the paths were asked for the
            # same picture and did not deliver the same canvas.
            if not ps: print(f"      ! size {a.size} vs {b.size}")
            b = b.resize(a.size, Image.BICUBIC)
        if hashlib.md5(open(off[i], "rb").read()).digest() == \
           hashlib.md5(open(grp[i], "rb").read()).digest():
            ident += 1
        ps.append(psnr(a, b))
    fin = [p for p in ps if np.isfinite(p)]
    all_psnr += fin; tot_shared += len(shared); tot_ident += ident
    print(f"  {c:<20}{len(off):>8}{len(grp):>7}{n_pair:>8}{ident:>10}"
          f"{(min(fin) if fin else float('nan')):>10.2f}"
          f"{(np.median(fin) if fin else float('nan')):>10.2f}")

print(f"\n  shared frames    : {tot_shared}")
print(f"  byte-identical   : {tot_ident} ({100*tot_ident/max(tot_shared,1):.1f}%)")
if all_psnr:
    a = np.array(all_psnr)
    print(f"  PSNR  min/med/max: {a.min():.2f} / {np.median(a):.2f} / {a.max():.2f} dB")
    print(f"  frames > {IDENTICAL_PSNR:.0f} dB : {int((a > IDENTICAL_PSNR).sum())}/{len(a)}")

print("\n--- verdict ---")
if tot_shared == 0:
    print("  INCONCLUSIVE: nothing to pair.")
elif tot_ident == tot_shared:
    print("  SAME PATH: byte-identical. The existing offline render IS Base; "
          "only +Harmonizer needs rendering.")
elif all_psnr and np.median(all_psnr) > IDENTICAL_PSNR:
    print(f"  EFFECTIVELY SAME: median {np.median(all_psnr):.1f} dB is jpeg-level "
          "noise, not content. Offline can stand as Base; say so in the caption.")
else:
    print(f"  DIFFERENT: median {np.median(all_psnr):.1f} dB. Render BOTH rows "
          "through gRPC -- otherwise the ablation confounds harmonizer with "
          "render path.")
