#!/usr/bin/env python3
"""Assets and camera model for the "Your office, anywhere" explainer.

Base photo: research/photos/unsplash-ort-4xM5cytsdMo.jpg, "black car interior" by Bram Van Oost
(Unsplash License): a Model 3 from the rear bench, between the front seats, facing forward.

Camera: a level pinhole looking down the car's axis, f = 2000 px, principal point on the horizon at
(1490, 690) (the far hedge line). The screen's measured outer glass (edge-fitted, below) sits at
z = 1.373 m, which makes its 536 px width the real 36.8 cm glass. A small homography HC maps the
model's projection of the flat screen onto the measured quad (the photo's slight roll); it is applied
to every projected point. Car frame = camera frame: x → right (passenger), y ↓, z → forward, metres.

The master is first run through the site's grade (research/tesla-web/tools/grade.py, the lead's recipe).

Outputs (public/demo/):
  office-{1400,2000,2700}.webp   the photo cropped to (150, 560, 2850, 2020), its screen area retouched
                                 to the dash behind it (the turned screen uncovers a sliver of it)
  office-screen-ui.webp          the screen's own glass (Tesla UI), rectified, for the flat/turning screen
  office-screen-mac.webp         the same glass streaming the Mac desktop (our render, brand wallpaper)
  office-macbook.webp            the MacBook's own display: brand wallpaper and the Dashcast window
and prints the model constants for Office.tsx.
"""
import json
import os
import subprocess
import sys

import cv2
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = os.path.abspath(os.path.join(HERE, '../..'))
SRC = os.path.join(SITE, 'research/photos/unsplash-ort-4xM5cytsdMo.jpg')
# The site's shared photo grade (the lead's recipe, matched to the hero cabin), applied to the whole
# master first: every derivative, and the screen's glass textures, come from the graded photo.
GRADE = os.path.join(SITE, 'research/tesla-web/tools/grade.py')
OUT = os.path.join(SITE, 'public/demo')
SCRATCH = os.environ.get('OFFICE_SCRATCH', '/tmp')
CROP = (150, 560, 2850, 2020)

F = 2000.0
CX, CY = 1490.0, 690.0
# Outer glass (silver rim) of the screen, fit_corners.py: 0.3–1.6 px rms per side.
Q0 = np.array([[1216.06, 724.53], [1751.43, 731.99], [1748.91, 1082.22], [1212.49, 1075.93]])
# Active area, same fit.
ACTIVE = np.array([[1233.42, 740.33], [1734.02, 747.14], [1730.69, 1059.02], [1229.45, 1062.4]])
GLASS_W = 0.368
TEX = (1072, 704)


def homography(src, dst):
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A += [[x, y, 1, 0, 0, 0, -u * x, -u * y, -u], [0, 0, 0, x, y, 1, -v * x, -v * y, -v]]
    _, _, vt = np.linalg.svd(np.array(A, float))
    H = vt[-1].reshape(3, 3)
    return H / H[2, 2]


def apply_h(H, pts):
    p = np.c_[np.asarray(pts, float), np.ones(len(pts))] @ H.T
    return p[:, :2] / p[:, 2:]


def project(pts):
    p = np.asarray(pts, float)
    return np.c_[CX + F * p[:, 0] / p[:, 2], CY + F * p[:, 1] / p[:, 2]]


def screen_model():
    c = Q0.mean(axis=0)
    w = np.linalg.norm(Q0[1] - Q0[0])
    D = F * GLASS_W / w
    h = GLASS_W * np.linalg.norm(Q0[3] - Q0[0]) / w
    X = (c[0] - CX) / F * D
    Y = (c[1] - CY) / F * D
    return {'c': [X, Y, D], 'w': GLASS_W, 'h': h}


def screen_corners(m, theta):
    """Glass corners turned toward the passenger by theta (about the screen's vertical centre line)."""
    X, Y, D = m['c']
    w, h = m['w'] / 2, m['h'] / 2
    out = []
    for sx, sy in [(-1, -1), (1, -1), (1, 1), (-1, 1)]:
        x, z = sx * w, 0.0
        # Facing the rear (-z); turning the face toward +x sends the right edge forward.
        xr = x * np.cos(theta)
        zr = x * np.sin(theta)
        out.append([X + xr, Y + sy * h, D + zr])
    return out


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    m = screen_model()
    HC = homography(project(screen_corners(m, 0)), Q0)
    turned = apply_h(HC, project(screen_corners(m, np.radians(30))))

    graded = os.path.join(SCRATCH, 'office-graded.png')
    subprocess.run([sys.executable, GRADE, SRC, graded], check=True, stdout=subprocess.DEVNULL)
    bgr = cv2.imread(graded)
    # Retouch: the dash behind the glass, wherever the turned screen no longer covers the flat one.
    mask = np.zeros(bgr.shape[:2], np.uint8)
    cv2.fillPoly(mask, [Q0.round().astype(np.int32)], 255)
    keep = np.zeros_like(mask)
    cv2.fillPoly(keep, [turned.round().astype(np.int32)], 255)
    keep = cv2.erode(keep, np.ones((9, 9), np.uint8))
    hole = cv2.dilate(mask, np.ones((9, 9), np.uint8))
    hole[keep > 0] = 0
    x0, y0 = Q0.min(axis=0).astype(int) - 60
    x1, y1 = Q0.max(axis=0).astype(int) + 60
    roi = bgr[y0:y1, x0:x1].copy()
    # The dash behind is made of horizontal bands (hedge, dash top, wood strip): carry each row in from
    # the dash just right of the hole, then soften the seam, so the bands run on unbroken.
    hr = hole[y0:y1, x0:x1] > 0
    fixed = roi.copy()
    for r in range(hr.shape[0]):
        xs = np.where(hr[r])[0]
        if not len(xs):
            continue
        right = min(xs.max() + 3, hr.shape[1] - 1)
        src = roi[r, right:right + 6].astype(np.float32).mean(axis=0)
        fixed[r, xs] = src.round().astype(np.uint8)
    blur = cv2.GaussianBlur(fixed, (0, 0), 1.2)
    soft = cv2.GaussianBlur(hr.astype(np.float32), (0, 0), 2)[..., None]
    fixed = (blur * soft + fixed * (1 - soft)).round().astype(np.uint8)
    # Behind the untouched middle, the glass stays: it is always covered by the live screen.
    out = bgr.copy()
    out[y0:y1, x0:x1] = fixed
    im = Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB)).crop(CROP)
    for w, q in [(1400, 80), (2000, 78), (2700, 74)]:
        r = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS) if w != im.width else im
        r.save(f'{OUT}/office-{w}.webp', quality=q, method=6)

    # Screen textures: the outer glass rectified to TEX.
    Hr = homography(Q0, [[0, 0], [TEX[0], 0], [TEX[0], TEX[1]], [0, TEX[1]]])
    glass = cv2.warpPerspective(bgr, Hr, TEX, flags=cv2.INTER_LANCZOS4)
    ui = Image.fromarray(cv2.cvtColor(glass, cv2.COLOR_BGR2RGB))
    ui.save(f'{OUT}/office-screen-ui.webp', quality=84, method=6)
    act = apply_h(Hr, ACTIVE)
    ax0, ay0 = act[:, 0].min(), act[:, 1].min()
    ax1, ay1 = act[:, 0].max(), act[:, 1].max()
    desk = Image.open(os.path.join(SCRATCH, 'desk-loop.png')).convert('RGB').resize((round(ax1 - ax0), round(ay1 - ay0)), Image.LANCZOS)
    mac = ui.copy()
    mac.paste(desk, (round(ax0), round(ay0)))
    mac.save(f'{OUT}/office-screen-mac.webp', quality=84, method=6)

    # The MacBook's own display (14", 3024×1964): brand wallpaper, the Dashcast window casting.
    W, H = 1100, 714
    wall = Image.open(os.path.join(SITE, 'public/shots/wallpaper.jpg')).convert('RGB')
    s = max(W / wall.width, H / wall.height)
    wall = wall.resize((round(wall.width * s), round(wall.height * s)), Image.LANCZOS)
    disp = wall.crop(((wall.width - W) // 2, (wall.height - H) // 2, (wall.width - W) // 2 + W, (wall.height - H) // 2 + H))
    win = Image.open(os.path.join(SITE, 'public/shots/main-casting-extend-dark@2x.webp')).convert('RGBA')
    k = (H * 0.86) / win.height
    win = win.resize((round(win.width * k), round(win.height * k)), Image.LANCZOS)
    disp.paste(win, ((W - win.width) // 2, round(H * 0.1)), win)
    bar = Image.new('RGBA', (W, 26), (0, 0, 0, 90))
    disp.paste(bar, (0, 0), bar)
    disp.save(f'{OUT}/office-macbook.webp', quality=82, method=6)

    print(json.dumps({
        'f': F, 'c': [CX, CY], 'crop': CROP[:2], 'HC': HC.round(9).tolist(), 'screen': m,
        'tex': TEX, 'Q0': Q0.tolist(), 'turned30': turned.round(2).tolist(),
    }, indent=1))


if __name__ == '__main__':
    main()
