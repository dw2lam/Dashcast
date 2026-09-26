#!/usr/bin/env python3
"""
One photo grade for the site, matched to the hero's cabin photo (public/demo/cabin-*.webp, I'M ZION, Unsplash):
cool-neutral, deep but not crushed blacks, restrained saturation, soft highlights.

    grade.py in.jpg out.jpg [--strength 1.0]      grade a master (JPEG/PNG/WebP in, JPEG/PNG/WebP out)
    grade.py --measure a.jpg [b.webp ...]         print the numbers this recipe works from

The recipe runs in sRGB-encoded values, in this order:
  1. levels          the darkest 0.5% of pixels' colour onto the reference's deep black (per channel, which also
                     neutralises a lifted, coloured floor); then one gain for all channels to the reference's white
  2. white balance   per-band channel gains toward the reference's balance (shadows a touch cool, mids neutral),
                     blended by luminance so shadows and mids can differ; gains are clamped
  3. shoulder        highlights above the knee roll off softly (applied to luminance, colour ratios kept)
  4. saturation      chroma scaled so the relative chroma (chroma / luminance, midtones) moves to the reference's
`--strength` scales every step (0 = untouched, 1 = the full recipe). Parameters are all here at the top.
"""
import argparse
import sys

import numpy as np
from PIL import Image

# ---- targets, measured on public/demo/cabin-2560.webp (2026-09-26; see --measure) ----
SHADOW_BALANCE = (0.977, 1.025)   # R/G, B/G for luminance 0.02–0.20: the reference's cool shadows
MID_BALANCE = (1.000, 1.000)      # R/G, B/G above 0.20: neutral (the reference's overall mean is 1.018 / 0.996)
BLACK_OUT = 0.006                 # output black point (≈1.5/255): deep, with the toe kept
WHITE_OUT = 0.985                 # output white point (≈251/255), the reference's p99
KNEE = 0.80                       # highlights above this roll off
REL_CHROMA = 0.075                # reference relative chroma (chroma / luminance, luminance 0.08–0.95)

# ---- limits, so the recipe never breaks a photo that is far from the reference ----
GAIN_RANGE = (0.75, 1.35)         # per-channel white-balance gain
BLACK_MAX_SHIFT = 0.14            # most the black point may move
WHITE_MAX_GAIN = 1.15             # most the highlights may be stretched
SAT_RANGE = (0.45, 1.20)          # chroma scale (never all the way to monochrome)
BAND_EDGE = (0.10, 0.35)          # luminance where the shadow balance hands over to the mid balance

LUMA = np.array([0.2126, 0.7152, 0.0722])


def luma(a):
    return a @ LUMA


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def balance(a, y, lo, hi):
    k = (y >= lo) & (y < hi)
    if k.sum() < 200:
        return None
    m = a[k].mean(0)
    return m[0] / max(m[1], 1e-6), m[2] / max(m[1], 1e-6)


def rel_chroma(a, y):
    c = a.max(-1) - a.min(-1)
    k = (y > 0.08) & (y < 0.95)
    return float((c[k] / y[k]).mean()) if k.any() else 0.0


def stats(a):
    y = luma(a)
    p = np.percentile(y, [0.2, 1, 50, 99, 99.8])
    return {
        "meanY": float(y.mean()) * 255,
        "black(p0.2)": p[0] * 255,
        "p1": p[1] * 255,
        "median": p[2] * 255,
        "p99": p[3] * 255,
        "white(p99.8)": p[4] * 255,
        "meanRGB": tuple(round(float(v) * 255, 1) for v in a.reshape(-1, 3).mean(0)),
        "shadows R/G,B/G": balance(a, y, 0.02, 0.20),
        "mids R/G,B/G": balance(a, y, 0.20, 0.95),
        "relChroma": rel_chroma(a, y),
    }


def grade(a, strength=1.0):
    s = float(strength)

    # 1. levels: the black point is the colour of the darkest 0.5% of pixels (a black-point eyedropper), taken
    #    onto BLACK_OUT per channel, which also turns a lifted, coloured floor neutral; then one gain for all
    #    channels so the white point lands on WHITE_OUT
    y = luma(a)
    bp = a[y <= np.percentile(y, 0.5)].mean(0)
    bp_out = bp + np.clip(BLACK_OUT - bp, -BLACK_MAX_SHIFT, BLACK_MAX_SHIFT) * s
    a = np.clip(a - bp + bp_out, 0, 1)
    y = luma(a)
    wp = np.percentile(y, 99.8)
    base = float(bp_out @ LUMA)
    gain = min((WHITE_OUT - base) / max(wp - base, 1e-3), WHITE_MAX_GAIN)
    gain = 1 + (gain - 1) * s
    a = np.clip((a - bp_out) * gain + bp_out, 0, 1)

    # 2. white balance: a gain per band, blended by luminance. Each band's gain also reaches the other band
    #    through the blend, so the gains are refined over a few passes until both bands land on target.
    a0 = a
    total_sh = np.ones(3)
    total_mid = np.ones(3)
    for _ in range(4):
        y = luma(a)
        w = smoothstep(BAND_EDGE[0], BAND_EDGE[1], y)[..., None]
        for band, target, lo, hi in (("sh", SHADOW_BALANCE, 0.02, 0.20), ("mid", MID_BALANCE, 0.20, 0.95)):
            m = balance(a, y, lo, hi)
            if m is None:
                continue
            g = np.array([target[0] / m[0], 1.0, target[1] / m[1]])
            if band == "sh":
                total_sh = np.clip(total_sh * g, *GAIN_RANGE)
            else:
                total_mid = np.clip(total_mid * g, *GAIN_RANGE)
        y0 = luma(a0)
        w = smoothstep(BAND_EDGE[0], BAND_EDGE[1], y0)[..., None]
        a = np.clip(a0 * (total_sh * (1 - w) + total_mid * w), 0, 1)
    a = a0 + (a - a0) * s

    # 3. shoulder on luminance: soft roll-off above the knee, colour ratios kept
    y = luma(a)
    over = np.clip((y - KNEE) / (1 - KNEE), 0, None)
    soft = KNEE + (1 - KNEE) * np.tanh(over * 1.2) / np.tanh(1.2)
    y2 = np.where(y > KNEE, y + (soft - y) * s, y)
    a = np.clip(a * (y2 / np.maximum(y, 1e-6))[..., None], 0, 1)

    # 4. saturation toward the reference's relative chroma
    y = luma(a)
    rc = rel_chroma(a, y)
    k = np.clip(REL_CHROMA / max(rc, 1e-6), *SAT_RANGE) ** s
    a = np.clip(y[..., None] + (a - y[..., None]) * k, 0, 1)
    return a


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float64) / 255


def save(a, path):
    im = Image.fromarray(np.round(a * 255).astype(np.uint8), "RGB")
    low = path.lower()
    if low.endswith((".jpg", ".jpeg")):
        im.save(path, quality=95, subsampling=0)
    elif low.endswith(".webp"):
        im.save(path, quality=95, method=6)
    else:
        im.save(path)


def show(name, st):
    print(f"{name}")
    for k, v in st.items():
        if isinstance(v, float):
            v = round(v, 3 if k == "relChroma" else 1)
        elif isinstance(v, tuple) and len(v) == 2:
            v = tuple(round(float(x), 3) for x in v)
        print(f"  {k:18s} {v}")


def small(a, n=1400):
    h, w = a.shape[:2]
    if max(h, w) <= n:
        return a
    im = Image.fromarray(np.round(a * 255).astype(np.uint8))
    im.thumbnail((n, n))
    return np.asarray(im, dtype=np.float64) / 255


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--measure", action="store_true", help="print the recipe's numbers for each path and exit")
    o = ap.parse_args()
    if o.measure:
        for p in o.paths:
            show(p, stats(small(load(p))))
        return
    if len(o.paths) != 2:
        sys.exit("usage: grade.py in.jpg out.jpg [--strength 1.0]")
    src, dst = o.paths
    a = load(src)
    b = grade(a, o.strength)
    save(b, dst)
    show(f"{src} (before)", stats(small(a)))
    show(f"{dst} (after, strength {o.strength})", stats(small(b)))


if __name__ == "__main__":
    main()
