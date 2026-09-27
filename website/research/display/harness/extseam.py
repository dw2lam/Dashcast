#!/usr/bin/env python3
"""ExtendVisual seam numbers (see extseam.mjs).

  extseam.py <outdir>/ext.json

black: max luminance in a ±2 device-px ring across the panel's (rounded) edge vs the bezel 4–8 px outside:
       anything above the bezel is photo light leaking past the panel.
white: the darkest value 1 device px inside the edge (a gap would show bezel there) and the brightest
       2–3 px outside it (the panel spilling past the glass edge).
Also writes 8x crops of the four corners and edge midpoints of the live render.
"""
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../tools'))
from homog import apply, fit  # noqa: E402

R = 10  # panel corner radius (px)


def outline(n_side=120, n_corner=16):
    W, H = 1920, 1200
    pts = []
    for (cx, cy, a0) in [(R, R, 180), (W - R, R, 270), (W - R, H - R, 0), (R, H - R, 90)]:
        for a in np.linspace(a0, a0 + 90, n_corner):
            t = np.radians(a)
            pts.append((cx + R * np.cos(t), cy + R * np.sin(t), np.cos(t), np.sin(t)))
    for s in np.linspace(0.03, 0.97, n_side):
        pts += [(R + s * (W - 2 * R), 0, 0, -1), (W, R + s * (H - 2 * R), 1, 0), (R + s * (W - 2 * R), H, 0, 1), (0, R + s * (H - 2 * R), -1, 0)]
    return pts


def bil(a, x, y):
    x0 = int(np.clip(np.floor(x), 0, a.shape[1] - 2))
    y0 = int(np.clip(np.floor(y), 0, a.shape[0] - 2))
    fx, fy = x - x0, y - y0
    return a[y0, x0] * (1 - fx) * (1 - fy) + a[y0, x0 + 1] * fx * (1 - fy) + a[y0 + 1, x0] * (1 - fx) * fy + a[y0 + 1, x0 + 1] * fx * fy


rows = json.load(open(sys.argv[1]))
out = os.path.dirname(sys.argv[1])
for r in rows:
    img = np.asarray(Image.open(r['file']).convert('RGB')).astype(float)
    lum = img @ np.array([0.2126, 0.7152, 0.0722])
    d = r['dpr']
    Hm = fit([[0, 0], [1920, 0], [1920, 1200], [0, 1200]], r['quad'])
    ring, bez, inside, spill = [], [], [], []
    for x, y, nx, ny in outline():
        p = apply(Hm, [[x, y], [x + nx * 40, y + ny * 40]])
        v = p[1] - p[0]
        v = v / np.hypot(*v)
        c = p[0] * d
        at = lambda o: bil(lum, c[0] + v[0] * o - 0.5, c[1] + v[1] * o - 0.5)
        ring += [at(o) for o in np.arange(-2, 2.01, 0.5)]
        bez += [at(o) for o in np.arange(4, 8.01, 1)]
        inside.append(at(-1))
        spill.append(max(at(2), at(3)))
    r.update(ring_max=float(np.max(ring)), bezel_max=float(np.max(bez)), inside_min=float(np.min(inside)), spill_max=float(np.max(spill)))
by = {}
for r in rows:
    by.setdefault((r['w'], r['h'], r['dpr']), {})[r['paint']] = r
print('size        dpr | black: ring max vs bezel max | white: min 1px inside, max 2-3px outside')
for (w, h, d), v in by.items():
    b, wt = v['black'], v['white']
    print(f'{w}x{h:<5} {d}   |  {b["ring_max"]:6.1f} vs {b["bezel_max"]:6.1f}            |  {wt["inside_min"]:6.1f}, {wt["spill_max"]:6.1f}')
# crops of the live render at 720x508@2
live = [r for r in rows if r['paint'] == 'live' and r['w'] == 720 and r['dpr'] == 2][0]
im = Image.open(live['file']).convert('RGB')
Hm = fit([[0, 0], [1920, 0], [1920, 1200], [0, 1200]], live['quad'])
pts = apply(Hm, [[0, 0], [960, 0], [1920, 0], [1920, 600], [1920, 1200], [960, 1200], [0, 1200], [0, 600]]) * 2
tiles = []
for x, y in pts:
    t = im.crop((int(x) - 16, int(y) - 16, int(x) + 16, int(y) + 16)).resize((192, 192), Image.NEAREST)
    tiles.append(t)
sheet = Image.new('RGB', (4 * 198, 2 * 198), 'white')
for i, t in enumerate(tiles):
    sheet.paste(t, ((i % 4) * 198, (i // 4) * 198))
sheet.save(os.path.join(out, 'ext-edges.png'))
