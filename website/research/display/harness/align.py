#!/usr/bin/env python3
"""Pixel alignment of the composited panel against the photo's own screen.

  align.py <outdir> <tag>   (reads photo-<tag>.png, mask-<tag>.png, quad-<tag>.json from align.mjs)

For the top, left and right sides (the photo's lit UI meets the black bezel there; the bottom is the
black dock on black glass) it samples profiles across the side at 9 positions and finds the step in
the photo (luminance) and in the mask (magenta coverage), each to sub-pixel, and prints the offsets.
Writes corner crops (photo | mask outline over photo) at 8x.
"""
import json
import sys

import numpy as np
from PIL import Image, ImageDraw

out, tag = sys.argv[1], sys.argv[2]
photo = np.asarray(Image.open(f'{out}/photo-{tag}.png').convert('RGB')).astype(float)
mask = np.asarray(Image.open(f'{out}/mask-{tag}.png').convert('RGB')).astype(float)
q = json.load(open(f'{out}/quad-{tag}.json'))
dpr = photo.shape[1] / q['host'][0]
Q = np.array(q['got']) * dpr
lum = photo.mean(axis=2)
# Magenta coverage, continuous (anti-aliased edge pixels count partially).
mag = np.clip(((mask[:, :, 0] + mask[:, :, 2]) / 2 - mask[:, :, 1]) / 255, 0, 1)


def step(profile):
    g = np.gradient(np.convolve(profile, np.ones(3) / 3, mode='same'))
    g[:3] = 0
    g[-3:] = 0
    i = int(np.argmax(np.abs(g)))
    a, b, c = g[i - 1], g[i], g[i + 1]
    d = a - 2 * b + c
    return i + (0.5 * (a - c) / d if d else 0)


def sample(img, p, n, r):
    offs = np.arange(-r, r + 1, 0.25)
    xs = p[0] + n[0] * offs
    ys = p[1] + n[1] * offs
    x0 = np.clip(np.floor(xs).astype(int), 0, img.shape[1] - 2)
    y0 = np.clip(np.floor(ys).astype(int), 0, img.shape[0] - 2)
    fx = xs - x0
    fy = ys - y0
    v = img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy) + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy
    return v, offs


res = {}
for name, (a, b) in {'top': (0, 1), 'right': (1, 2), 'left': (3, 0)}.items():
    P, R = Q[a], Q[b]
    d = R - P
    t = d / np.hypot(*d)
    n = np.array([-t[1], t[0]])
    diffs = []
    for s in np.linspace(0.12, 0.88, 9):
        c = P + d * s
        r = max(6, 5 * dpr)
        lp, offs = sample(lum, c, n, r)
        mp, _ = sample(mag, c, n, r)
        sp = step(lp) * 0.25 - r
        sm = step(mp) * 0.25 - r
        diffs.append(sp - sm)
    res[name] = {'mean_px': round(float(np.mean(diffs)) / dpr, 3), 'max_abs_px': round(float(np.max(np.abs(diffs))) / dpr, 3)}
print(json.dumps({'tag': tag, 'css_px_offsets_photo_minus_panel': res, 'numeric_corner_err_css_px': [round(e, 4) for e in q['err']], 'screen_width_css_px': round(q['screenW'], 1)}))

crops = []
for i, c in enumerate(Q[:2]):
    x, y = int(c[0]), int(c[1])
    box = (x - 14, y - 14, x + 14, y + 14)
    a = Image.fromarray(photo.astype(np.uint8)).crop(box).resize((224, 224), Image.NEAREST)
    m = Image.fromarray((mag * 255).astype(np.uint8)).crop(box).resize((224, 224), Image.NEAREST)
    b = a.copy()
    edge = np.asarray(m).astype(float)
    ey = np.abs(np.diff(edge, axis=0, prepend=0)) + np.abs(np.diff(edge, axis=1, prepend=0))
    over = np.asarray(b).copy()
    over[ey > 0.35] = [255, 0, 255]
    crops += [a, Image.fromarray(over)]
sheet = Image.new('RGB', (224 * 4 + 30, 224), 'white')
for i, im in enumerate(crops):
    sheet.paste(im, (i * 234, 0))
sheet.save(f'{out}/corners-{tag}.png')
