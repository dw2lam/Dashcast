#!/usr/bin/env python3
"""Builds the shipped cabin assets from research/photos/unsplash-ziontech-u4FO_unYC8I.jpg.

Measurements (see ../NOTES.md): the lit UI region (panel 0,0 → 1920,1100; the dock below is black on
black glass) was edge-fitted with fit_corners.py; the homography from those four corners gives the
active area's corners, the rectified screen and the glass reflection field.

Outputs to public/demo/: cabin-{1600,2560,3840,5504}.webp (photo cropped to y 360–4000, its screen
blacked out), screen-ui.webp (the photo's own screen, rectified to 1920×1200) and screen-glare.png
(reflection field sampled from the bezel ring and the dock, panel space, for a `screen` blend).

The shipped photo carries no UI pixels: the active area plus BLEED px of the bezel (the lens/JPEG
halo of the lit UI) is inpainted from the surrounding bezel and feathered into it, so an
anti-aliasing seam at the live panel's edge can only ever reveal dark glass. The real UI pixels
reach the page through screen-ui.webp alone.
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
BLEED = 6
FEATHER = 4
RING = 18
WHITE = [[2116.84, 1736.65], [3446.74, 1735.27], [3454.48, 2497.6], [2112.72, 2496.45]]


def blackout(bgr, H, active):
    """The photo with its screen replaced by dark glass, feathered into the real bezel.

    The fill is a Coons patch (transfinite interpolation) of the bezel's own colour sampled on a
    ring RING panel px outside the active area, so it meets the bezel seamlessly and stays smooth
    inside. `H` maps panel px to photo pixel-index coords; `active` is the active area (edge coords).
    """
    E = RING
    step = 4
    gw, gh = (1920 + 2 * E) // step + 1, (1200 + 2 * E) // step + 1

    def ring(pts):
        p = apply(H, pts).astype(np.float32)
        v = cv2.remap(bgr, p[:, 0].reshape(1, -1), p[:, 1].reshape(1, -1), cv2.INTER_LINEAR)[0].astype(np.float32)
        v = cv2.medianBlur(v.reshape(1, -1, 3).astype(np.uint8), 5).reshape(-1, 3).astype(np.float32)
        return cv2.GaussianBlur(v.reshape(1, -1, 3), (0, 0), 2).reshape(-1, 3)

    xs = np.linspace(-E, 1920 + E, gw)
    ys = np.linspace(-E, 1200 + E, gh)
    T = ring([[x, -E] for x in xs])
    B = ring([[x, 1200 + E] for x in xs])
    L = ring([[-E, y] for y in ys])
    R = ring([[1920 + E, y] for y in ys])
    u = np.linspace(0, 1, gw)[None, :, None]
    v = np.linspace(0, 1, gh)[:, None, None]
    c00, c10, c01, c11 = T[0], T[-1], B[0], B[-1]
    F = (1 - v) * T[None] + v * B[None] + (1 - u) * L[:, None] + u * R[:, None]
    F -= (1 - u) * (1 - v) * c00 + u * (1 - v) * c10 + (1 - u) * v * c01 + u * v * c11

    x0, y0 = (active.min(axis=0) - 40).astype(int)
    x1, y1 = (active.max(axis=0) + 40).astype(int)
    G = np.array([[step, 0, -E], [0, step, -E], [0, 0, 1]], dtype=float)
    M = np.array([[1, 0, -x0], [0, 1, -y0], [0, 0, 1]], dtype=float) @ H @ G
    fill = cv2.warpPerspective(np.clip(F, 0, 255).astype(np.float32), M, (x1 - x0, y1 - y0), flags=cv2.INTER_LINEAR)

    ss = 4
    poly = ((active - 0.5 - [x0, y0]) * ss).round().astype(np.int32)
    m = np.zeros(((y1 - y0) * ss, (x1 - x0) * ss), np.uint8)
    cv2.fillPoly(m, [poly], 255, lineType=cv2.LINE_AA)
    m = cv2.resize(m, (x1 - x0, y1 - y0), interpolation=cv2.INTER_AREA)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * BLEED + 1, 2 * BLEED + 1))
    hole = cv2.dilate((m > 0).astype(np.uint8) * 255, k)
    dist = cv2.distanceTransform(255 - hole, cv2.DIST_L2, 5)
    a = np.clip(1 - dist / FEATHER, 0, 1)[..., None]
    roi = bgr[y0:y1, x0:x1].astype(np.float32)
    out = bgr.copy()
    out[y0:y1, x0:x1] = np.clip(fill * a + roi * (1 - a), 0, 255).round().astype(np.uint8)
    return out


def main():
    # The edge fit reports pixel-index coordinates (pixel i's centre is i); CSS and the panel geometry
    # use edges (pixel i covers [i, i+1]). Hc maps panel edges to photo edges; H is the same mapping
    # in index coordinates, for cv2.
    Hc = fit([[0, 0], [1920, 0], [1920, 1100], [0, 1100]], [[x + 0.5, y + 0.5] for x, y in WHITE])
    T = lambda d: np.array([[1, 0, d], [0, 1, d], [0, 0, 1]], dtype=float)
    H = T(-0.5) @ Hc @ T(0.5)
    active = apply(Hc, [[0, 0], [1920, 0], [1920, 1200], [0, 1200]])
    bgr = cv2.imread(SRC)

    im = Image.fromarray(cv2.cvtColor(blackout(bgr, H, active), cv2.COLOR_BGR2RGB)).crop((0, CROP_Y[0], 5512, CROP_Y[1]))
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
