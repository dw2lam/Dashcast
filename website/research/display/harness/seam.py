#!/usr/bin/env python3
"""Ring luminance around the composited panel (see seam.mjs).

  seam.py <outdir>/<label>.json

The panel is painted black, so any light in a 4-device-px ring straddling its edge (±2 px) is the
photo showing through. Reference: the bezel 4–8 device px outside the edge. Samples follow the
panel's rounded outline (18 panel px radius) through the same homography the page uses.
"""
import json
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, __import__('os').path.join(__import__('os').path.dirname(__file__), '../tools'))
from homog import apply, fit  # noqa: E402


def outline(r=18, n_side=160, n_corner=24):
    pts = []
    W, H = 1920, 1200
    for (cx, cy, a0) in [(r, r, 180), (W - r, r, 270), (W - r, H - r, 0), (r, H - r, 90)]:
        for a in np.linspace(a0, a0 + 90, n_corner):
            t = np.radians(a)
            pts.append((cx + r * np.cos(t), cy + r * np.sin(t), np.cos(t), np.sin(t)))
    for s in np.linspace(0.02, 0.98, n_side):
        pts += [(r + s * (W - 2 * r), 0, 0, -1), (W, r + s * (H - 2 * r), 1, 0), (r + s * (W - 2 * r), H, 0, 1), (0, r + s * (H - 2 * r), -1, 0)]
    return pts


def bilinear(a, x, y):
    x0 = np.clip(np.floor(x).astype(int), 0, a.shape[1] - 2)
    y0 = np.clip(np.floor(y).astype(int), 0, a.shape[0] - 2)
    fx = np.clip(x - x0, 0, 1)
    fy = np.clip(y - y0, 0, 1)
    return a[y0, x0] * (1 - fx) * (1 - fy) + a[y0, x0 + 1] * fx * (1 - fy) + a[y0 + 1, x0] * (1 - fx) * fy + a[y0 + 1, x0 + 1] * fx * fy


rows = json.load(open(sys.argv[1]))
for r in rows:
    img = np.asarray(Image.open(r['file']).convert('RGB')).astype(float)
    lum = img @ np.array([0.2126, 0.7152, 0.0722])
    dpr = r['dpr']
    Hm = fit([[0, 0], [1920, 0], [1920, 1200], [0, 1200]], r['quad'])
    ring, bez = [], []
    for x, y, nx, ny in outline():
        p = apply(Hm, [[x, y], [x + nx * 4, y + ny * 4]])
        d = p[1] - p[0]
        d = d / np.hypot(*d)
        c = (p[0] - [r['clip']['x'], r['clip']['y']]) * dpr
        for o in np.arange(-2, 2.01, 0.5):
            ring.append(bilinear(lum, np.array([c[0] + d[0] * o]), np.array([c[1] + d[1] * o]))[0])
        for o in np.arange(4, 8.01, 1):
            bez.append(bilinear(lum, np.array([c[0] + d[0] * o]), np.array([c[1] + d[1] * o]))[0])
    ring = np.array(ring)
    bez = np.array(bez)
    r['ring_max'] = round(float(ring.max()), 1)
    r['ring_p99'] = round(float(np.percentile(ring, 99)), 1)
    r['bezel_max'] = round(float(bez.max()), 1)
    r['bezel_p99'] = round(float(np.percentile(bez, 99)), 1)
    print(f"{r['framing']:7} {r['state']:7} {r['w']}x{r['h']}@{dpr}  ring max {r['ring_max']:6.1f} p99 {r['ring_p99']:6.1f} | bezel max {r['bezel_max']:6.1f} p99 {r['bezel_p99']:6.1f}")
worst = max(rows, key=lambda r: r['ring_max'] - r['bezel_max'])
print('worst excess over bezel:', round(worst['ring_max'] - worst['bezel_max'], 1), worst['framing'], worst['state'], f"{worst['w']}x{worst['h']}@{worst['dpr']}")
json.dump(rows, open(sys.argv[1], 'w'))
