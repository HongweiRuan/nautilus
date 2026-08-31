#!/usr/bin/env python3
"""Which offline pose source does the gRPC path behave like?

Cross-compares every render variant of a clip against every other, and reports
BOTH raw PSNR and PSNR after removing a whole-image translation (estimated by
phase correlation).

The two numbers answer different questions and conflating them is what made an
earlier run of this investigation wrong:

  * raw PSNR       — how different do the pictures look to a metric. A shift of
                     a dozen pixels drops this to ~20 dB while the pictures are
                     indistinguishable by eye.
  * aligned PSNR   — how different is the CONTENT once the viewpoint offset is
                     taken out. This is what says whether one renderer is
                     actually blurrier than another.

A pair that is ~20 dB raw and ~37 dB aligned differs by WHERE the camera was,
not by how well it drew. A pair that stays low after alignment differs in
quality.
"""
import glob, os, sys, itertools
import numpy as np
from PIL import Image
from numpy.fft import fft2, ifft2

ROOT = "/avl-west/fidelity_eval/posesrc"
FRAMES = (10, 25, 40)
MARGIN = 48          # crop before scoring: a rolled image wraps at the edges


def variant_frames(d):
    ps = glob.glob(os.path.join(d, "**", "*.jpg"), recursive=True) + \
         glob.glob(os.path.join(d, "**", "*.jpeg"), recursive=True)
    def key(p):
        stem = os.path.splitext(os.path.basename(p))[0]
        return (0, int(stem)) if stem.isdigit() else (1, stem)
    return sorted(ps, key=key)


def psnr(a, b):
    m = ((a.astype(np.float64) - b.astype(np.float64)) ** 2).mean()
    return float("inf") if m == 0 else 10 * np.log10(255.0 ** 2 / m)


def phase_shift(a, b):
    A, B = fft2(a), fft2(b)
    cps = A * np.conj(B)
    cps /= np.maximum(np.abs(cps), 1e-9)
    r = np.real(ifft2(cps))
    dy, dx = np.unravel_index(np.argmax(r), r.shape)
    if dy > a.shape[0] // 2: dy -= a.shape[0]
    if dx > a.shape[1] // 2: dx -= a.shape[1]
    return int(dy), int(dx)


def compare(pa, pb):
    im = Image.open(pa).convert("RGB")
    A = np.asarray(im, np.float64)
    B = np.asarray(Image.open(pb).convert("RGB").resize(im.size, Image.BICUBIC), np.float64)
    dy, dx = phase_shift(A[..., 1], B[..., 1])
    Bs = np.roll(np.roll(B, dy, 0), dx, 1)
    m = MARGIN
    return psnr(A[m:-m, m:-m], B[m:-m, m:-m]), psnr(A[m:-m, m:-m], Bs[m:-m, m:-m]), (dy, dx)


clips = sys.argv[1:] or sorted(os.listdir(ROOT))
for clip in clips:
    d = os.path.join(ROOT, clip)
    variants = {v: variant_frames(os.path.join(d, v))
                for v in sorted(os.listdir(d)) if os.path.isdir(os.path.join(d, v))}
    variants = {k: v for k, v in variants.items() if v}
    print(f"\n=== {clip} ===")
    for v, fs in variants.items():
        print(f"  {v:<34} {len(fs)} frames")
    if len(variants) < 2:
        print("  (nothing to compare)"); continue
    print(f"\n  {'pair':<52}{'raw':>8}{'aligned':>9}{'shift':>12}")
    for a, b in itertools.combinations(sorted(variants), 2):
        fa, fb = variants[a], variants[b]
        rows = []
        for i in FRAMES:
            if i >= min(len(fa), len(fb)): continue
            rows.append(compare(fa[i], fb[i]))
        if not rows: continue
        raw = np.mean([r[0] for r in rows])
        ali = np.mean([r[1] for r in rows])
        sh = ", ".join(f"{r[2][0]:+d}/{r[2][1]:+d}" for r in rows[:2])
        print(f"  {a[:24]:<25}vs {b[:24]:<25}{raw:>8.2f}{ali:>9.2f}  {sh}")
