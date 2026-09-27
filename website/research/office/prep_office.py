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
  office-{1400,2000,2700}.webp   the graded photo cropped to (150, 560, 2850, 2020), untouched
  extend-{960,1480}.webp         the Extend card's crop (620, 450, 2100, 1450), the screen's active area
                                 blacked out to dark glass so only the live panel shows a picture
  office-desk.webp               the office screen's second-display picture (our render), photographed:
                                 mapped onto the photo's own screen levels, softened, the photo's grain
  office-macbook.webp            the MacBook's own display: brand wallpaper and the Dashcast window, likewise
  office-board.webp, office-deck.webp   the board's carpet and the MacBook's top case, in the photo's tones
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


# The Extend card's crop (full-res px) and how its screen is blacked out.
EXT_CROP = (620, 450, 2100, 1450)
RING = 30       # panel px outside the active area where the dark-glass fill is sampled (≈8 photo px, black bezel)
BLEED = 3       # photo px of bezel the fill also covers (the lit UI's halo)
FEATHER = 3
# The photographed screen's tone (graded master, active area): what streamed pictures are mapped onto.
SCREEN_BLACK, SCREEN_WHITE = 15.0, 179.0
PHOTO_NOISE = 5.0


def rng():
    return np.random.default_rng(7)


def grain(a, sigma, blur=0.6):
    """The photo's own grain (luminance-correlated, a little soft), added to a float image."""
    n = rng().normal(0, sigma, a.shape[:2]).astype(np.float32)
    if blur:
        n = cv2.GaussianBlur(n, (0, 0), blur)
    return a + n[..., None]


def photographed(img, blur=0.8, noise=PHOTO_NOISE * 1.4):
    """A picture on the car's screen as the camera saw the photo's own screen: its black and white levels,
    a touch of softness and the photo's grain."""
    a = np.asarray(img, np.float32)
    a = SCREEN_BLACK + a * (SCREEN_WHITE - SCREEN_BLACK) / 255
    a = cv2.GaussianBlur(a, (0, 0), blur)
    return Image.fromarray(np.clip(grain(a, noise), 0, 255).round().astype(np.uint8))


def blackout_active(bgr, H):
    """The photo's active screen area as dark glass: a Coons patch of the black bezel sampled RING panel px
    outside it, covering BLEED px past the edge and feathered over FEATHER px into the real bezel.
    H maps panel px (1920×1200) to photo pixel-index coords."""
    E, step = RING, 4
    gw, gh = (1920 + 2 * E) // step + 1, (1200 + 2 * E) // step + 1

    def ring(pts):
        q = apply_h(H, pts).astype(np.float32)
        v = cv2.remap(bgr, q[:, 0].reshape(1, -1), q[:, 1].reshape(1, -1), cv2.INTER_LINEAR)[0].astype(np.float32)
        return cv2.GaussianBlur(v.reshape(1, -1, 3), (0, 0), 12).reshape(-1, 3)

    xs = np.linspace(-E, 1920 + E, gw)
    ys = np.linspace(-E, 1200 + E, gh)
    T, B = ring([[x, -E] for x in xs]), ring([[x, 1200 + E] for x in xs])
    L, R = ring([[-E, y] for y in ys]), ring([[1920 + E, y] for y in ys])
    u = np.linspace(0, 1, gw)[None, :, None]
    v = np.linspace(0, 1, gh)[:, None, None]
    F = (1 - v) * T[None] + v * B[None] + (1 - u) * L[:, None] + u * R[:, None]
    F -= (1 - u) * (1 - v) * T[0] + u * (1 - v) * T[-1] + (1 - u) * v * B[0] + u * v * B[-1]
    act = apply_h(H, [[0, 0], [1920, 0], [1920, 1200], [0, 1200]])
    x0, y0 = (act.min(axis=0) - 40).astype(int)
    x1, y1 = (act.max(axis=0) + 40).astype(int)
    G = np.array([[step, 0, -E], [0, step, -E], [0, 0, 1]], float)
    M = np.array([[1, 0, -x0], [0, 1, -y0], [0, 0, 1]], float) @ H @ G
    fill = cv2.warpPerspective(np.clip(F, 0, 255).astype(np.float32), M, (x1 - x0, y1 - y0), flags=cv2.INTER_LINEAR)
    fill = grain(fill, PHOTO_NOISE * 0.8)
    ss = 4
    m = np.zeros(((y1 - y0) * ss, (x1 - x0) * ss), np.uint8)
    cv2.fillPoly(m, [((act - [x0, y0]) * ss).round().astype(np.int32)], 255, lineType=cv2.LINE_AA)
    m = cv2.resize(m, (x1 - x0, y1 - y0), interpolation=cv2.INTER_AREA)
    hole = cv2.dilate((m > 0).astype(np.uint8) * 255, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * BLEED + 1, 2 * BLEED + 1)))
    a = np.clip(1 - cv2.distanceTransform(255 - hole, cv2.DIST_L2, 5) / FEATHER, 0, 1)[..., None]
    out = bgr.copy()
    roi = bgr[y0:y1, x0:x1].astype(np.float32)
    out[y0:y1, x0:x1] = np.clip(fill * a + roi * (1 - a), 0, 255).round().astype(np.uint8)
    return out


def board_texture():
    """The trunk's subfloor cover, 1 px = 1 mm, far edge (toward the windshield) at the top: black carpet on
    a hard board, lit from the windshield, in the graded photo's carpet tones."""
    w, h = 1100, 420
    y = np.linspace(0, 1, h)[:, None]
    base = np.array([44, 45, 48], np.float32) * (1 - y) + np.array([30, 31, 33], np.float32) * y
    a = np.broadcast_to(base[:, None, :], (h, w, 3)).copy()
    fibre = cv2.GaussianBlur(rng().normal(0, 3, (h, w)).astype(np.float32), (0, 0), 0.5)
    a += fibre[..., None]
    edge = np.minimum.reduce([np.arange(w)[None, :].repeat(h, 0), (w - 1 - np.arange(w))[None, :].repeat(h, 0),
                              np.arange(h)[:, None].repeat(w, 1), (h - 1 - np.arange(h))[:, None].repeat(w, 1)]).astype(np.float32)
    a *= (0.72 + 0.28 * np.clip(edge / 10, 0, 1))[..., None]
    a[:4] += 22  # the far edge catches the windshield light
    return Image.fromarray(np.clip(grain(a, PHOTO_NOISE * 0.6), 0, 255).round().astype(np.uint8))


def deck_texture():
    """A 14" MacBook's top case, 5 px per mm, hinge at the top: space-grey aluminium lit from the windshield,
    the keyboard in its well, the trackpad, the speaker grilles."""
    k = 5
    w, h = 312 * k, 221 * k
    y = np.linspace(0, 1, h)[:, None]
    # Dimmer than a product shot: the cabin's light, lighter at the hinge (toward the windshield).
    base = np.array([88, 90, 95], np.float32) * (1 - y) + np.array([60, 62, 66], np.float32) * y
    a = np.broadcast_to(base[:, None, :], (h, w, 3)).copy()
    a += cv2.GaussianBlur(rng().normal(0, 2.5, (h, w)).astype(np.float32), (0, 0), 1.5)[..., None]
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    from PIL import ImageDraw
    d = ImageDraw.Draw(im)
    kx0, kx1, ky0, ky1 = 18 * k, (312 - 18) * k, 12 * k, 118 * k
    d.rounded_rectangle([kx0, ky0, kx1, ky1], radius=3 * k, fill=(40, 41, 44))
    rows = [(1, 15), (1, 14), (1.35, 13), (1.6, 12), (2.1, 11), (1, 9)]
    ry = ky0 + 2 * k
    rh = (ky1 - ky0 - 4 * k) / len(rows)
    for i, (_, n) in enumerate(rows):
        kw = (kx1 - kx0 - 4 * k) / n
        for j in range(n):
            x = kx0 + 2 * k + j * kw
            d.rounded_rectangle([x + 0.7 * k, ry + i * rh + 0.7 * k, x + kw - 0.7 * k, ry + (i + 1) * rh - 0.7 * k], radius=int(1.2 * k), fill=(18, 18, 20))
    px0, px1 = 95 * k, (312 - 95) * k
    d.rounded_rectangle([px0, 130 * k, px1, (221 - 12) * k], radius=4 * k, fill=(76, 78, 82), outline=(66, 68, 72), width=2)
    for gx in (7 * k, (312 - 15) * k):
        for yy in range(ky0 + 3 * k, ky1 - 2 * k, int(1.6 * k)):
            for xx in range(gx, gx + 8 * k, int(1.6 * k)):
                d.ellipse([xx, yy, xx + 3, yy + 3], fill=(50, 51, 54))
    a = cv2.GaussianBlur(np.asarray(im, np.float32), (0, 0), 1.6)
    return Image.fromarray(np.clip(grain(a, PHOTO_NOISE * 1.6, blur=1.2), 0, 255).round().astype(np.uint8))


def main():
    os.makedirs(SCRATCH, exist_ok=True)
    m = screen_model()
    HC = homography(project(screen_corners(m, 0)), Q0)

    graded = os.path.join(SCRATCH, 'office-graded.png')
    subprocess.run([sys.executable, GRADE, SRC, graded], check=True, stdout=subprocess.DEVNULL)
    bgr = cv2.imread(graded)

    # Office section: the graded photo as it is; the screen stays as photographed.
    im = Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)).crop(CROP)
    for w, q in [(1400, 80), (2000, 78), (2700, 74)]:
        r = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS) if w != im.width else im
        r.save(f'{OUT}/office-{w}.webp', quality=q, method=6)

    # Extend card: the screen's active area blacked out, so only the live panel shows a picture.
    Hp = homography([[0, 0], [1920, 0], [1920, 1200], [0, 1200]], ACTIVE - 0.5)
    ext = Image.fromarray(cv2.cvtColor(blackout_active(bgr, Hp), cv2.COLOR_BGR2RGB)).crop(EXT_CROP)
    for w, q in [(960, 80), (1480, 78)]:
        r = ext.resize((w, round(ext.height * w / ext.width)), Image.LANCZOS) if w != ext.width else ext
        r.save(f'{OUT}/extend-{w}.webp', quality=q, method=6)

    # The office screen's second-display picture (step 3): our render, photographed.
    desk = Image.open(os.path.join(SCRATCH, 'desk-loop.png')).convert('RGB').resize((1000, 625), Image.LANCZOS)
    photographed(desk).save(f'{OUT}/office-desk.webp', quality=84, method=6)

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
    photographed(disp, blur=1.0).save(f'{OUT}/office-macbook.webp', quality=82, method=6)
    disp.save(os.path.join(HERE, 'macbook-display.png'))

    # The rendered MacBook (render_macbook.py with the Sketchfab model), when there is one: composited onto
    # the ungraded photo, graded with the photo's own recipe, then cut back out by its alpha, so the sprite
    # carries exactly the photo's grade; the photo's grain on top.
    render = os.path.join(HERE, 'macbook-render.png')
    if os.path.exists(render):
        raw = cv2.imread(SRC)
        rgba = cv2.imread(render, cv2.IMREAD_UNCHANGED)
        T = np.array([[1, 0, CROP[0]], [0, 1, CROP[1]], [0, 0, 1]], float)
        warped = cv2.warpPerspective(rgba, HC @ T, (raw.shape[1], raw.shape[0]), flags=cv2.INTER_LINEAR)
        a = warped[..., 3:4].astype(np.float32) / 255
        comp = (warped[..., :3].astype(np.float32) * a + raw.astype(np.float32) * (1 - a)).round().astype(np.uint8)
        cpath = os.path.join(SCRATCH, 'macbook-comp.png')
        cv2.imwrite(cpath, comp)
        subprocess.run([sys.executable, GRADE, cpath, cpath], check=True, stdout=subprocess.DEVNULL)
        g = cv2.imread(cpath).astype(np.float32)
        g = grain(g, PHOTO_NOISE)
        sprite = np.dstack([np.clip(g, 0, 255), a * 255]).astype(np.uint8)
        sprite = cv2.cvtColor(sprite, cv2.COLOR_BGRA2RGBA)
        Image.fromarray(sprite).crop(CROP).save(f'{OUT}/office-macbook-render.webp', quality=86, method=6)

    board_texture().save(f'{OUT}/office-board.webp', quality=82, method=6)
    deck_texture().save(f'{OUT}/office-deck.webp', quality=82, method=6)

    print(json.dumps({'HC': HC.round(9).tolist(), 'active_crop': (ACTIVE - CROP[:2]).round(2).tolist(),
                      'active_ext': (ACTIVE - EXT_CROP[:2]).round(2).tolist(), 'glass_ext': (Q0 - EXT_CROP[:2]).round(2).tolist()}))


if __name__ == '__main__':
    main()
