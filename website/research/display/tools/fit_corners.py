#!/usr/bin/env python3
"""Refine a screen's four corners by edge fitting.

  fit_corners.py <photo> "<tlx,tly trx,try brx,bry blx,bly>" [--r 18] [--n 60] [--crops outdir] [--sign auto|+|-]

For each side, samples n points between the approximate corners (skipping the rounded ends), takes the
luminance profile across the side (±r px), finds the strongest step (sub-pixel), fits a line with
two-pass outlier rejection and intersects neighbouring lines. Prints the corners, per-side residuals, and
optionally writes zoomed corner crops with the fitted lines drawn for visual checking.
"""
import json
import sys

import numpy as np
from PIL import Image, ImageDraw


def bilinear(a, x, y):
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    fx = x - x0
    fy = y - y0
    x0 = np.clip(x0, 0, a.shape[1] - 2)
    y0 = np.clip(y0, 0, a.shape[0] - 2)
    return (a[y0, x0] * (1 - fx) * (1 - fy) + a[y0, x0 + 1] * fx * (1 - fy) + a[y0 + 1, x0] * (1 - fx) * fy + a[y0 + 1, x0 + 1] * fx * fy)


def fit_side(L, p, q, inward, r, n, sign):
    d = np.array(q) - np.array(p)
    length = np.hypot(*d)
    t = d / length
    nrm = np.array(inward)
    pts = []
    for s in np.linspace(0.08, 0.92, n):
        c = np.array(p) + d * s
        offs = np.arange(-r, r + 1, 0.25)
        xs = c[0] + nrm[0] * offs
        ys = c[1] + nrm[1] * offs
        prof = bilinear(L, xs, ys)
        prof = np.convolve(prof, np.ones(5) / 5, mode='same')
        g = np.gradient(prof)
        g[:6] = 0
        g[-6:] = 0
        if sign == '+':
            i = int(np.argmax(g))
        elif sign == '-':
            i = int(np.argmin(g))
        else:
            i = int(np.argmax(np.abs(g)))
        if 1 <= i < len(g) - 1:
            a, b, cc = g[i - 1], g[i], g[i + 1]
            den = a - 2 * b + cc
            sub = 0.5 * (a - cc) / den if den != 0 else 0
        else:
            sub = 0
        o = offs[i] + sub * 0.25
        pts.append((c + nrm * o, abs(g[i])))
    P = np.array([x for x, _ in pts])
    for _ in range(2):
        mean = P.mean(axis=0)
        u, s_, vt = np.linalg.svd(P - mean)
        dirv = vt[0]
        nv = np.array([-dirv[1], dirv[0]])
        res = (P - mean) @ nv
        keep = np.abs(res) < max(1.0, 2.5 * np.std(res))
        P = P[keep]
    mean = P.mean(axis=0)
    u, s_, vt = np.linalg.svd(P - mean)
    dirv = vt[0]
    nv = np.array([-dirv[1], dirv[0]])
    res = (P - mean) @ nv
    return mean, dirv, float(np.sqrt((res ** 2).mean())), len(P)


def intersect(a, b):
    (p, d), (q, e) = a, b
    A = np.array([d, -e]).T
    t = np.linalg.solve(A, q - p)
    return p + d * t[0]


def main():
    src, qs = sys.argv[1], sys.argv[2]
    args = sys.argv[3:]
    opt = lambda k, dflt: args[args.index(k) + 1] if k in args else dflt
    r = float(opt('--r', 18))
    n = int(opt('--n', 60))
    sign = opt('--sign', 'auto')
    crops = opt('--crops', None)
    Q = [tuple(map(float, p.split(','))) for p in qs.split()]
    im = Image.open(src).convert('RGB')
    L = np.asarray(im.convert('L')).astype(np.float32)
    cx = sum(p[0] for p in Q) / 4
    cy = sum(p[1] for p in Q) / 4
    sides = []
    for i in range(4):
        p, q = Q[i], Q[(i + 1) % 4]
        mid = ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2)
        d = np.array(q) - np.array(p)
        nrm = np.array([-d[1], d[0]]) / np.hypot(*d)
        if (cx - mid[0]) * nrm[0] + (cy - mid[1]) * nrm[1] < 0:
            nrm = -nrm
        mean, dirv, rms, k = fit_side(L, p, q, nrm, r, n, sign)
        sides.append(((mean, dirv), rms, k))
    corners = []
    for i in range(4):
        prev = sides[(i - 1) % 4][0]
        cur = sides[i][0]
        corners.append(intersect(prev, cur))
    out = {
        'corners': [[round(float(c[0]), 2), round(float(c[1]), 2)] for c in corners],
        'side_rms_px': [round(s[1], 3) for s in sides],
        'side_points': [s[2] for s in sides],
    }
    print(json.dumps(out))
    if crops:
        for i, c in enumerate(corners):
            z = 8
            box = (int(c[0]) - 24, int(c[1]) - 24, int(c[0]) + 24, int(c[1]) + 24)
            cr = im.crop(box).resize((48 * z, 48 * z), Image.NEAREST)
            dr = ImageDraw.Draw(cr)
            for (mean, dirv), _, _ in sides:
                a = (mean - dirv * 5000 - np.array(box[:2])) * z
                b = (mean + dirv * 5000 - np.array(box[:2])) * z
                dr.line([tuple(a), tuple(b)], fill=(255, 0, 255), width=1)
            x = (c[0] - box[0]) * z
            y = (c[1] - box[1]) * z
            dr.ellipse([x - 4, y - 4, x + 4, y + 4], outline=(0, 255, 0))
            cr.save(f'{crops}/corner{i}.png')


if __name__ == '__main__':
    main()
