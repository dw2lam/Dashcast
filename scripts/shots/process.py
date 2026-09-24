"""Turns scripts/shots/capture.sh's raw window captures into the website's screenshot set.

    python3 scripts/shots/process.py [raw-dir] [out-dir]
        raw-dir  default website/shots-raw/captures
        out-dir  default website/public/shots

- Every window image gets the same transparent margin around the window body: 56 pt left and
  right, 38 pt above, 74 pt below (what `screencapture -l` gives a titled window's shadow). The menu
  bar panel's smaller shadow is padded out to match, so the site positions every window with one
  rule: image width = window width + 112 pt.
- Exports `<scene>-<appearance>@2x.webp` (native Retina pixels) and `@1x.webp`, WebP with alpha.
- Writes `card-main-dark.png` and `card-main-light.png`: the casting window on its stage wallpaper,
  2400 x 1260 (the og-image ratio, at 2x), for the og card and the portfolio card.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
RAW = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "website/shots-raw/captures"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "website/public/shots"
SCALE = 2
PAD = {"left": 56, "top": 38, "right": 56, "bottom": 74}  # points
WALLPAPERS = {
    "dark": ROOT / "website/shots-raw/wallpaper-dark-5k.png",
    "light": ROOT / "website/shots-raw/wallpaper-light-5k.png",
}


def window_size(shot):
    """Window size in pixels. A sheet's capture is its parent window with the sheet attached."""
    if shot["name"].startswith("setup-"):
        return 460 * SCALE, 580 * SCALE
    return round(shot["frame"]["width"] * SCALE), round(shot["frame"]["height"] * SCALE)


def window_top(alpha, width):
    """First row of the window body in the centre column (the shadow there is far below 200)."""
    column = alpha[:, width // 2]
    return int(np.argmax(column >= 200))


def normalise(image, shot):
    w, h = window_size(shot)
    alpha = np.asarray(image)[..., 3]
    left = (image.width - w) // 2
    top = window_top(alpha, image.width)
    # Snap to the titled-window geometry when within the 1 px rim ambiguity.
    if abs(top - PAD["top"] * SCALE) <= 1 and left == PAD["left"] * SCALE:
        top = PAD["top"] * SCALE
    canvas = Image.new("RGBA", (w + (PAD["left"] + PAD["right"]) * SCALE, h + (PAD["top"] + PAD["bottom"]) * SCALE))
    canvas.paste(image, (PAD["left"] * SCALE - left, PAD["top"] * SCALE - top))
    return canvas


def half(image):
    """Downscale in premultiplied alpha so the shadow and corners keep clean edges."""
    return image.convert("RGBa").resize((image.width // 2, image.height // 2), Image.LANCZOS).convert("RGBA")


def save_webp(image, path):
    image.save(path, "WEBP", quality=90, alpha_quality=100, method=6)


def card(window, appearance):
    width, height = 2400, 1260
    wall = Image.open(WALLPAPERS[appearance]).convert("RGB")
    scale = max(width / wall.width, height / wall.height)
    wall = wall.resize((round(wall.width * scale), round(wall.height * scale)), Image.LANCZOS)
    top = round((wall.height - height) * 0.55)
    wall = wall.crop(((wall.width - width) // 2, top, (wall.width - width) // 2 + width, top + height))
    canvas = wall.convert("RGBA")
    # The window body is 1160 px tall at 2x; 0.9 leaves room above and below at 1260.
    fit = 0.9
    shot = window.convert("RGBa").resize((round(window.width * fit), round(window.height * fit)), Image.LANCZOS).convert("RGBA")
    body_top = PAD["top"] * SCALE * fit
    body_h = 580 * SCALE * fit
    x = (width - shot.width) // 2
    y = round((height - body_h) / 2 - body_top)
    # A slightly deeper ambient shadow than the window's own, so it sits on the photo-like wallpaper.
    ambient = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    alpha = shot.getchannel("A").point(lambda v: 255 if v >= 250 else 0)
    blob = Image.new("RGBA", shot.size, (0, 0, 0, 90))
    ambient.paste(blob, (x, y + 30), alpha)
    ambient = ambient.filter(ImageFilter.GaussianBlur(60))
    canvas.alpha_composite(ambient)
    canvas.alpha_composite(shot, (x, y))
    return canvas.convert("RGB")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    written = []
    for appearance in ("dark", "light"):
        manifest = RAW / f"{appearance}-shots.json"
        if not manifest.exists():
            continue
        for shot in json.loads(manifest.read_text())["shots"]:
            image = normalise(Image.open(RAW / shot["file"]).convert("RGBA"), shot)
            stem = f"{shot['name']}-{appearance}"
            save_webp(image, OUT / f"{stem}@2x.webp")
            save_webp(half(image), OUT / f"{stem}@1x.webp")
            written.append((stem, image.width // SCALE, image.height // SCALE))
            if shot["name"] == "main-casting-extend":
                card(image, appearance).save(OUT / f"card-main-{appearance}.png", optimize=True)
    for stem, w, h in written:
        print(f"{stem:36s} {w} x {h} pt")


if __name__ == "__main__":
    main()
