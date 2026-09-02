#!/usr/bin/env python3
"""Which rig vertical offset makes render-grpc match the eval frame?

Scores each swept tz against the eval render with plain PSNR after removing a
whole-image translation. No horizon detector, no focal-length assumption: the
tz that wins IS the height discrepancy, in metres.

Frames are paired by index. render-grpc and the eval both walk the clip's
training frames in time order at the same rate, verified separately (grpc frame
i best-matches offline frame i by a clear margin over i+-1).
"""
import glob, os, sys
import numpy as np
from PIL import Image
from numpy.fft import fft2, ifft2

SWEEP = "/avl-west/fidelity_eval/zsweep/f6ee61f4305d5564s1"
EVAL = os.environ.get("EVAL",
    "/avl-west/fidelity_eval/rigeval/f6ee61f4-fwd14/frames/{:05d}/cam_f0.jpg")
FRAMES = [int(x) for x in os.environ.get("FRAMES", "0,10,22,40").split(",")]
MARGIN = 60


def psnr(a, b):
    m = ((a - b) ** 2).mean()
    return float("inf") if m == 0 else 10 * np.log10(255.0 ** 2 / m)


def aligned_psnr(A, B):
    Fa, Fb = fft2(A), fft2(B)
    c = Fa * np.conj(Fb); c /= np.maximum(np.abs(c), 1e-9)
    r = np.real(ifft2(c)); dy, dx = np.unravel_index(np.argmax(r), r.shape)
    if dy > A.shape[0] // 2: dy -= A.shape[0]
    if dx > A.shape[1] // 2: dx -= A.shape[1]
    Bs = np.roll(np.roll(B, dy, 0), dx, 1)
    m = MARGIN
    return psnr(A[m:-m, m:-m], Bs[m:-m, m:-m]), (int(dy), int(dx))


def frames_of(d):
    ps = glob.glob(os.path.join(d, "**", "*.jp*g"), recursive=True)
    key = lambda p: (0, int(os.path.splitext(os.path.basename(p))[0])) \
        if os.path.splitext(os.path.basename(p))[0].isdigit() else (1, p)
    return sorted(ps, key=key)


tzs = sorted(
    (float(os.path.basename(d)[2:]), d)
    for d in glob.glob(f"{SWEEP}/tz*") if os.path.isdir(d))
if not tzs:
    sys.exit(f"no sweep output under {SWEEP}")

print(f"{'tz (m)':>8}" + "".join(f"{'f'+str(f):>10}" for f in FRAMES) + f"{'mean':>10}")
best = (None, -1)
for tz, d in tzs:
    fs = frames_of(d)
    row, vals = [], []
    for f in FRAMES:
        ep = EVAL.format(f)
        if f >= len(fs) or not os.path.exists(ep):
            row.append(f"{'—':>10}"); continue
        A = np.asarray(Image.open(ep).convert("L"), np.float64)
        B = np.asarray(Image.open(fs[f]).convert("L").resize(
            Image.open(ep).size, Image.BICUBIC), np.float64)
        p, _ = aligned_psnr(A, B)
        vals.append(p); row.append(f"{p:10.2f}")
    mean = np.mean(vals) if vals else float("nan")
    if vals and mean > best[1]: best = (tz, mean)
    print(f"{tz:>8.1f}" + "".join(row) + f"{mean:>10.2f}")
if best[0] is not None:
    print(f"\n  best tz = {best[0]:+.1f} m at {best[1]:.2f} dB")
    print(f"  -> the eval camera sits {abs(best[0]):.1f} m "
          f"{'BELOW' if best[0] < 0 else 'ABOVE'} render-grpc's")
