#!/usr/bin/env python3
"""Builds the shipped cabin assets from research/photos/unsplash-ziontech-u4FO_unYC8I.jpg.

Measurements (see ../NOTES.md): the lit UI region (panel 0,0 → 1920,1100; the dock below is black on
black glass) was edge-fitted with fit_corners.py; the homography from those four corners gives the
active area's corners, the rectified screen and the glass reflection field.

Outputs to public/demo/: cabin-{1600,2560,3840,5504}.webp (photo cropped to y 360–4000),
screen-ui.webp (the photo's own screen, rectified to 1920×1200) and screen-glare.png (reflection
field sampled from the bezel ring and the dock, panel space, for a `screen` blend).
"""
import json
import os

import cv2
import numpy as np
from PIL import Image

from homog import apply, fit

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.abspath(os.path.join(HERE, '../../..'))
SRC = os.path.join(SITE, 'research/photos/unsplash-ziontech-u4FO_unYC8I.jpg')
OUT = os.path.join(SITE, 'public/demo')
CROP_Y = (360, 4000)
WHITE = [[2116.84, 1736.65], [3446.74, 1735.27], [3454.48, 2497.6], [2112.72, 2496.45]]


def main():
    # The edge fit reports pixel-index coordinates (pixel i's centre is i); CSS and the panel geometry
    # use edges (pixel i covers [i, i+1]). Hc maps panel edges to photo edges; H is the same mapping
    # in index coordinates, for cv2.
    Hc = fit([[0, 0], [1920, 0], [1920, 1100], [0, 1100]], [[x + 0.5, y + 0.5] for x, y in WHITE])
    T = lambda d: np.array([[1, 0, d], [0, 1, d], [0, 0, 1]], dtype=float)
    H = T(-0.5) @ Hc @ T(0.5)
    active = apply(Hc, [[0, 0], [1920, 0], [1920, 1200], [0, 1200]])
    bgr = cv2.imread(SRC)

    im = Image.open(SRC).convert('RGB').crop((0, CROP_Y[0], 5512, CROP_Y[1]))
    for w, q in [(1600, 80), (2560, 78), (3840, 74), (5504, 70)]:
        r = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
        r.save(f'{OUT}/cabin-{w}.webp', quality=q, method=6)

    rect = cv2.warpPerspective(bgr, np.linalg.inv(H), (1920, 1200), flags=cv2.INTER_LANCZOS4)
    Image.fromarray(cv2.cvtColor(rect, cv2.COLOR_BGR2RGB)).save(f'{OUT}/screen-ui.webp', quality=86, method=6)

    # Reflection field: bezel ring 14 px outside the active area plus the dock's black gaps.
    lum = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY).astype(np.float32)
    lum = cv2.medianBlur(lum.astype(np.uint8), 5).astype(np.float32)

    def ring(pts):
        p = apply(Hc, pts) - 0.5
        return np.array([lum[int(round(y)), int(round(x))] for x, y in p])

    xs = np.linspace(0, 1920, 49)
    ys = np.linspace(0, 1200, 31)
    top = ring([[x, -14] for x in xs])
    bot = ring([[x, 1214] for x in xs])
    left = ring([[-14, y] for y in ys])
    right = ring([[1934, y] for y in ys])
    sm = lambda a: np.convolve(np.pad(a, 3, mode='edge'), np.ones(7) / 7, mode='valid')
    top, bot, left, right = sm(top), sm(bot), sm(left), sm(right)
    gw, gh = 96, 60
    u = np.linspace(0, 1, gw)[None, :]
    v = np.linspace(0, 1, gh)[:, None]
    T = np.interp(u, np.linspace(0, 1, len(top)), top)
    B = np.interp(u, np.linspace(0, 1, len(bot)), bot)
    L = np.interp(v, np.linspace(0, 1, len(left)), left)
    R = np.interp(v, np.linspace(0, 1, len(right)), right)
    corners = (1 - u) * (1 - v) * T[:, :1] + u * (1 - v) * T[:, -1:] + (1 - u) * v * B[:, :1] + u * v * B[:, -1:]
    F = (1 - v) * T + v * B + (1 - u) * L + u * R - corners
    F = cv2.GaussianBlur(F.astype(np.float32), (0, 0), 3)
    F = np.clip(F, 0, 255)
    g = np.dstack([F, F, F]).round().astype(np.uint8)
    Image.fromarray(g, 'RGB').save(f'{OUT}/screen-glare.png', optimize=True)

    dock = rect[1185:1198, :, :].reshape(-1, 3).astype(float)
    print(json.dumps({
        'active_corners_photo': active.round(2).tolist(),
        'active_corners_cropped': (active - [0, CROP_Y[0]]).round(2).tolist(),
        'crop_size': [5512, CROP_Y[1] - CROP_Y[0]],
        'glare_range': [float(F.min()), float(F.max())],
        'dock_black_rgb_p50': np.median(dock, axis=0).tolist(),
    }, indent=1))


if __name__ == '__main__':
    main()
