#!/usr/bin/env python3
"""Compose the Dashcast DMG window background from the Codex-generated art (light-glass).

    python3 Design/dmg/build_background.py            # uses the ART / CROP settings below
    python3 Design/dmg/build_background.py --art work/light-X.png --crop LEFT TOP WIDTH

Writes, next to this file:
    background.png      660 x 400  (72 dpi)
    background@2x.png  1320 x 800  (144 dpi)
    background.tiff     multi-resolution (tiffutil -cathidpicheck) — what scripts/make-dmg.sh ships
    work/label-check@2x.png   the background with Finder's labels simulated (black 12 pt)

Pipeline: crop the render onto the window -> make sure Finder's black labels have contrast
(lightens a label strip only if it needs it) -> per-scale dither + crisp SF Pro caption.

Layout contract (points, origin top-left of the Finder window content) — must match
scripts/make-dmg.sh: 660 x 400 window, 128 pt icons centred at (170,190) and (490,190),
Finder labels centred ~(x, 272) in BLACK (macOS 26/27 draws background-picture labels black,
even in Dark Mode), caption typeset here at y≈342 so it stays visible even when a user has
Finder's tab bar switched on (content then ends at y≈364).
Palette: Design/icon/BRAND.md (VERSION: light-glass).
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
W, H = 660, 400
S = 2                                  # master scale
ICONS = {"Dashcast": (170, 190), "Applications": (490, 190)}
LABEL_Y = 272                          # measured centre of Finder's 12 pt label line
LABEL_HALF_W = 40                      # "Dashcast.app"/"Applications" at 12 pt ≈ 66–72 pt wide
LABEL_TARGET_CONTRAST = 7.0            # black text on the label strip (WCAG AAA)
CAPTION = "Drag Dashcast to Applications"
CAPTION_Y = 342                        # optical centre of the caption line
CAPTION_RGB = (91, 102, 120)           # slate #5B6678 (BRAND.md)

# Source art (Codex render) and the crop of it that maps onto the 660x400 window.
# CROP = (left, top, width) in source pixels; height follows from the 1.65:1 window.
ART = HERE / "work" / "light-E.png"      # Codex render, concept L-E "Silk glass"
CROP = (0, 59, 1536)

SF = "/System/Library/Fonts/SFNS.ttf"


def to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def rel_lum(rgb) -> np.ndarray:
    return to_linear(np.asarray(rgb, dtype=np.float64)) @ np.array([0.2126, 0.7152, 0.0722])


def label_box(cx: float, s: int) -> tuple[int, int, int, int]:
    return (round((cx - LABEL_HALF_W) * s), round((LABEL_Y - 7) * s),
            round((cx + LABEL_HALF_W) * s), round((LABEL_Y + 7) * s))


def worst_contrast(a: np.ndarray, s: int) -> dict[str, float]:
    """Lowest black-text contrast over each label's box, sampled on 2 x 2 pt cells."""
    out = {}
    for name, (cx, _) in ICONS.items():
        x0, y0, x1, y1 = label_box(cx, s)
        c = 2 * s
        region = a[y0:y1, x0:x1][: (y1 - y0) // c * c, : (x1 - x0) // c * c]
        cells = region.reshape(region.shape[0] // c, c, region.shape[1] // c, c, 3).mean(axis=(1, 3))
        out[name] = (rel_lum(cells).min() + 0.05) / 0.05
    return out


def radial(shape, cx, cy, rx, ry, power=1.0) -> np.ndarray:
    yy, xx = np.mgrid[0:shape[0], 0:shape[1]]
    return np.exp(-((((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2) ** power))


def ensure_label_contrast(a: np.ndarray, s: int) -> np.ndarray:
    """Soft white lift under a label, only as much as black text needs (a no-op on clean art)."""
    for name, (cx, _) in ICONS.items():
        if worst_contrast(a, s)[name] >= LABEL_TARGET_CONTRAST:
            continue
        mask = radial(a.shape, cx * s, LABEL_Y * s, 70 * s, 16 * s, power=1.6)[..., None]
        lo, hi = 0.0, 1.0
        for _ in range(18):
            mid = (lo + hi) / 2
            ok = worst_contrast(a + (1 - a) * mask * mid, s)[name] >= LABEL_TARGET_CONTRAST
            lo, hi = (lo, mid) if ok else (mid, hi)
        print(f"  lightened {name} label strip by {hi:.2f}")
        a = a + (1 - a) * mask * hi
    return a


def dither(img: Image.Image, amount: float, seed: int = 7) -> Image.Image:
    """Fine monochrome grain (std-dev in 8-bit levels): breaks banding in the long soft gradients."""
    a = np.asarray(img, dtype=np.float32)
    noise = np.random.default_rng(seed).normal(0.0, amount, a.shape[:2])[..., None]
    return Image.fromarray(np.clip(a + noise + 0.5, 0, 255).astype(np.uint8))


def sf(px: float, weight: int, opsz: int = 17) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(SF, round(px))
    f.set_variation_by_axes([100, opsz, 400, weight])   # width, optical size, GRAD, weight
    return f


def draw_caption(img: Image.Image, s: int) -> None:
    ImageDraw.Draw(img).text((W * s / 2, CAPTION_Y * s), CAPTION, font=sf(12 * s, weight=500),
                             fill=CAPTION_RGB, anchor="mm")


def simulate_labels(img: Image.Image, s: int) -> Image.Image:
    sim = img.copy()
    d = ImageDraw.Draw(sim)
    for name, (cx, _) in ICONS.items():
        d.text((cx * s, LABEL_Y * s), name, font=sf(12 * s, weight=400), fill=(0, 0, 0), anchor="mm")
    return sim


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--art", type=pathlib.Path, default=ART, help="source render (default: %(default)s)")
    ap.add_argument("--crop", type=int, nargs=3, metavar=("LEFT", "TOP", "WIDTH"), default=CROP)
    args = ap.parse_args()

    left, top, width = args.crop
    src = Image.open(args.art).convert("RGB")
    art = src.crop((left, top, left + width, top + round(width * H / W))).resize((W * S, H * S), Image.LANCZOS)
    a = ensure_label_contrast(np.asarray(art, dtype=np.float64) / 255, S)
    master = Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8))

    for s, name in ((2, "background@2x.png"), (1, "background.png")):
        img = master if s == S else master.resize((W * s, H * s), Image.LANCZOS)
        img = dither(img, amount=0.8 if s == 2 else 0.6)
        draw_caption(img, s)
        img.save(HERE / name, dpi=(72 * s, 72 * s), optimize=True)
        cons = worst_contrast(np.asarray(img, dtype=np.float64) / 255, s)
        print(f"{name}: worst black-label contrast " + ", ".join(f"{k} {v:.1f}:1" for k, v in cons.items()))
        if s == 2:
            (HERE / "work").mkdir(exist_ok=True)
            simulate_labels(img, s).save(HERE / "work" / "label-check@2x.png")

    subprocess.run(["tiffutil", "-cathidpicheck", str(HERE / "background.png"), str(HERE / "background@2x.png"),
                    "-out", str(HERE / "background.tiff")], check=True)
    print("wrote", HERE / "background.tiff")


if __name__ == "__main__":
    main()
