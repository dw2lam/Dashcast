"""Dashcast icon post-processing: Apple continuous-corner squircle mask, glass rim, baked shadow,
iconset/icns build and small-size legibility previews.

Usage:
  python3 iconkit.py master  <art.png> <out-1024.png> [--zoom Z] [--dx DX] [--dy DY] [--crop auto|none]
  python3 iconkit.py iconset <master-1024.png> <out.iconset> [--small <small-master-1024.png>]
  python3 iconkit.py preview <master-1024.png> <out-prefix> [--small <small-master-1024.png>]
"""
import sys, argparse
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops

CANVAS = 1024
BODY = 824            # Apple macOS icon grid: 824px body inside 1024 canvas (100px inset)
INSET = (CANVAS - BODY) // 2
RADIUS = 185.4        # ~22.5% of 824, Apple template corner radius (continuous corners)
SS = 4                # supersampling for mask edges


def _cubic(p0, p1, p2, p3, n=24):
    t = np.linspace(0, 1, n)[:, None]
    p0, p1, p2, p3 = map(np.array, (p0, p1, p2, p3))
    return ((1 - t) ** 3) * p0 + 3 * ((1 - t) ** 2) * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


def continuous_rrect_points(x0, y0, x1, y1, r):
    """Polygon for Apple's continuous-corner rounded rect (PaintCode's reverse-engineered
    UIBezierPath coefficients). Returns list of (x, y)."""
    pts = []
    a, b, c, d = 1.52866483, 1.08849323, 0.86840689, 0.63149399
    e, f, g, h = 0.07491100, 0.37282392, 0.16905210, 0.0

    def corner(cx, cy, sx, sy, swap):
        # build top-right corner in local coords (edge along +x then turning +y), then map
        segs = [
            ((-a, 0), (-b, 0), (-c, 0), (-d, e)),
            ((-d, e), (-f, g), (-g, f), (-e, d)),
            ((-e, d), (0, c), (0, b), (0, a)),
        ]
        out = []
        for s in segs:
            curve = _cubic(*s)
            for (u, v) in curve:
                if swap:
                    u, v = v, u
                out.append((cx + sx * u * r, cy + sy * v * r))
        return out

    # clockwise: top-right, bottom-right, bottom-left, top-left
    pts += corner(x1, y0, 1, 1, False)            # top edge -> right edge
    pts += corner(x1, y1, -1, 1, True)            # right edge -> bottom edge
    pts += corner(x0, y1, -1, -1, False)          # bottom edge -> left edge
    pts += corner(x0, y0, 1, -1, True)            # left edge -> top edge
    return pts


def squircle_mask(size, x0, y0, x1, y1, r):
    big = Image.new("L", (size * SS, size * SS), 0)
    pts = continuous_rrect_points(x0 * SS, y0 * SS, x1 * SS, y1 * SS, r * SS)
    ImageDraw.Draw(big).polygon(pts, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def auto_crop(img):
    """If Codex drew its own rounded tile on a light/flat margin, crop to that tile's bbox."""
    a = np.asarray(img.convert("RGB")).astype(np.float32)
    h, w, _ = a.shape
    corner = np.concatenate([a[:8, :8].reshape(-1, 3), a[:8, -8:].reshape(-1, 3),
                             a[-8:, :8].reshape(-1, 3), a[-8:, -8:].reshape(-1, 3)])
    bg = np.median(corner, axis=0)
    diff = np.abs(a - bg).sum(axis=2)
    mid = a[h // 2 - 20:h // 2 + 20, w // 2 - 20:w // 2 + 20].reshape(-1, 3)
    # only crop if the corner colour is clearly different from the tile (i.e. a margin exists)
    if np.abs(np.median(mid, axis=0) - bg).sum() < 40 and bg.mean() < 60:
        return img, None
    ys, xs = np.where(diff > 60)
    if len(xs) == 0:
        return img, None
    box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
    bw, bh = box[2] - box[0], box[3] - box[1]
    if bw > 0.97 * w and bh > 0.97 * h:
        return img, None
    return img.crop(box), box


TILE_TOP = (255, 255, 255)     # light-glass tile gradient (used when Codex returns transparency)
TILE_BOTTOM = (238, 242, 247)


def flatten_on_tile(art):
    """Codex sometimes returns RGBA with a transparent background; paint the light tile under it."""
    if art.mode not in ("RGBA", "LA", "P"):
        return art.convert("RGB")
    rgba = art.convert("RGBA")
    if np.asarray(rgba)[..., 3].min() == 255:
        return rgba.convert("RGB")
    w, h = rgba.size
    t = np.linspace(0, 1, h)[:, None, None]
    bg = (np.array(TILE_TOP, np.float32) * (1 - t) + np.array(TILE_BOTTOM, np.float32) * t)
    bg = np.repeat(bg, w, axis=1).astype(np.uint8)
    base = Image.fromarray(bg, "RGB").convert("RGBA")
    base.alpha_composite(rgba)
    return base.convert("RGB")


def build_master(art, zoom=1.0, dx=0, dy=0, crop="auto", rim=True, shadow=True):
    art = flatten_on_tile(art)
    box = None
    if crop == "auto":
        art, box = auto_crop(art)
    # fit art into the 824 body (square crop around centre), optional zoom to push away edges
    w, h = art.size
    s = min(w, h)
    art = art.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))
    tgt = int(round(BODY * zoom))
    art = art.resize((tgt, tgt), Image.LANCZOS)
    body = Image.new("RGB", (BODY, BODY))
    ox = (BODY - tgt) // 2 + dx
    oy = (BODY - tgt) // 2 + dy
    body.paste(art, (ox, oy))

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    mask = squircle_mask(CANVAS, INSET, INSET, INSET + BODY, INSET + BODY, RADIUS)

    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    layer.paste(body, (INSET, INSET))
    layer.putalpha(mask)

    if rim:
        layer = add_rim(layer, mask)

    if shadow:
        canvas = add_shadow(canvas, mask)
    canvas = Image.alpha_composite(canvas, layer)
    return canvas, box


def add_rim(layer, mask):
    """Glass edge: thin specular rim bright at the top, fading down; faint dark inner edge at bottom."""
    m = np.asarray(mask).astype(np.float32) / 255.0
    er1 = np.asarray(mask.filter(ImageFilter.MinFilter(5))).astype(np.float32) / 255.0
    er2 = np.asarray(mask.filter(ImageFilter.MinFilter(13))).astype(np.float32) / 255.0
    ring_thin = np.clip(m - er1, 0, 1)          # ~2px
    ring_soft = np.clip(m - er2, 0, 1)          # ~6px
    ring_soft = np.asarray(Image.fromarray((ring_soft * 255).astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(3))).astype(np.float32) / 255.0 * m
    yy = np.linspace(0, 1, CANVAS)[:, None] * np.ones((1, CANVAS))
    # vertical position within body
    t = np.clip((yy - INSET / CANVAS) / (BODY / CANVAS), 0, 1)
    top_w = np.clip(1.0 - t * 1.6, 0, 1) ** 1.4
    bot_w = np.clip((t - 0.55) / 0.45, 0, 1)

    a = np.asarray(layer).astype(np.float32)
    rgb = a[..., :3]
    if is_light(a, m):
        # light glass tile: faint cool-grey edge (heavier toward the bottom) + white inner sheen at top
        edge = np.array([150, 162, 182], np.float32)
        k_edge = (ring_thin * (0.16 + 0.22 * t) )[..., None]
        rgb = rgb * (1 - k_edge) + edge * k_edge
        inner = np.clip(er1 - np.asarray(mask.filter(ImageFilter.MinFilter(9))).astype(np.float32) / 255.0, 0, 1)
        k_in = (inner * 0.55 * top_w)[..., None]
        rgb = rgb * (1 - k_in) + np.array([255, 255, 255], np.float32) * k_in
        a[..., :3] = np.clip(rgb, 0, 255)
        return Image.fromarray(a.astype(np.uint8), "RGBA")
    light = np.array([234, 244, 255], np.float32)
    k_light = (ring_thin * (0.10 + 0.45 * top_w) + ring_soft * 0.10 * top_w)[..., None]
    rgb = rgb * (1 - k_light) + light * k_light
    # subtle bottom rim glint (reflected light) - keeps the glass slab reading as a solid
    k_bot = (ring_thin * 0.14 * bot_w)[..., None]
    rgb = rgb * (1 - k_bot) + np.array([150, 200, 255], np.float32) * k_bot
    a[..., :3] = np.clip(rgb, 0, 255)
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def is_light(a, m):
    """True when the tile body (alpha-weighted) is predominantly light."""
    w = m if m.ndim == 2 else m[..., 0]
    lum = (a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722)
    return float((lum * w).sum() / max(w.sum(), 1)) > 165


def add_shadow(canvas, mask):
    """macOS-style baked shadow: soft ambient drop + tight contact shadow."""
    out = canvas
    for (oy, blur, op) in ((12, 16, 0.32), (3, 4, 0.22)):
        sh = Image.new("L", (CANVAS, CANVAS), 0)
        sh.paste(mask, (0, oy))
        sh = sh.filter(ImageFilter.GaussianBlur(blur))
        sh = sh.point(lambda v: int(v * op))
        layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        layer.putalpha(sh)
        out = Image.alpha_composite(out, layer)
    return out


SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def downscale(img, px):
    """High-quality downscale in premultiplied space, stepwise, light sharpen at small sizes."""
    im = img.convert("RGBA")
    a = np.asarray(im).astype(np.float32) / 255.0
    pm = a.copy(); pm[..., :3] *= pm[..., 3:4]
    cur = Image.fromarray((pm * 255).astype(np.uint8), "RGBA")
    size = im.size[0]
    while size // 2 >= px * 2:
        size //= 2
        cur = cur.resize((size, size), Image.LANCZOS)
    cur = cur.resize((px, px), Image.LANCZOS)
    b = np.asarray(cur).astype(np.float32) / 255.0
    al = b[..., 3:4]
    rgb = np.where(al > 1e-4, b[..., :3] / np.maximum(al, 1e-4), 0)
    outa = np.concatenate([np.clip(rgb, 0, 1), al], axis=2)
    out = Image.fromarray((outa * 255 + 0.5).astype(np.uint8), "RGBA")
    if px <= 64:
        rgbim = out.convert("RGB").filter(ImageFilter.UnsharpMask(radius=0.6, percent=35, threshold=2))
        rgbim.putalpha(out.getchannel("A"))
        out = rgbim
    if px <= 32:
        out = pixel_rim(out)
    return out


def pixel_rim(img):
    """At 16/32 px the 1024-px glass rim is sub-pixel; draw a 1px specular edge at target res so the
    dark tile keeps its silhouette on dark backgrounds (brighter at top, faint at the bottom)."""
    a = np.asarray(img).astype(np.float32)
    al = a[..., 3] / 255.0
    body = (al > 0.5).astype(np.float32)
    er = np.asarray(Image.fromarray((body * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(3))).astype(np.float32) / 255.0
    ring = np.clip(body - er, 0, 1)
    # include the anti-aliased outer pixels at reduced strength
    ring = np.maximum(ring, np.clip(al - body, 0, 1) * 0.6)
    n = a.shape[0]
    t = np.linspace(0, 1, n)[:, None] * np.ones((1, n))
    if is_light(a, body):
        w = 0.20 + 0.16 * t        # cool-grey edge, 0.20 at top -> 0.36 at bottom
        col = np.array([120, 132, 152], np.float32)
    else:
        w = 0.34 - 0.20 * t        # 0.34 at top -> 0.14 at bottom
        col = np.array([214, 232, 255], np.float32)
    k = (ring * w)[..., None]
    a[..., :3] = a[..., :3] * (1 - k) + col * k
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")


def build_iconset(master_path, outdir, small_path=None, small_max=32):
    import os
    os.makedirs(outdir, exist_ok=True)
    master = Image.open(master_path).convert("RGBA")
    small = Image.open(small_path).convert("RGBA") if small_path else None
    for (pt, scale) in SIZES:
        px = pt * scale
        src = small if (small is not None and px <= small_max) else master
        im = master.copy() if px == 1024 else downscale(src, px)
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        im.save(os.path.join(outdir, name))
    print("iconset written:", outdir)


def build_preview(master_path, prefix, small_path=None, small_max=32):
    master = Image.open(master_path).convert("RGBA")
    small = Image.open(small_path).convert("RGBA") if small_path else None
    sizes = [16, 32, 64]
    for theme, bg in (("light", (236, 236, 238)), ("dark", (30, 30, 32))):
        # actual pixel size strip
        icons = [downscale(small if (small is not None and s <= small_max) else master, s) for s in sizes]
        pad = 12
        W = sum(sizes) + pad * (len(sizes) + 1)
        H = max(sizes) + pad * 2
        strip = Image.new("RGBA", (W, H), bg + (255,))
        x = pad
        for s, ic in zip(sizes, icons):
            strip.alpha_composite(ic, (x, pad + (max(sizes) - s)))
            x += s + pad
        strip.save(f"{prefix}-{theme}.png")
        # 4x nearest-neighbour zoom for inspection, plus the 128 for reference
        Z = 4
        zoomed = strip.resize((W * Z, H * Z), Image.NEAREST)
        ref = downscale(master, 128)
        big = Image.new("RGBA", (zoomed.width + 128 + pad * 2 * Z, zoomed.height), bg + (255,))
        big.alpha_composite(zoomed, (0, 0))
        big.alpha_composite(ref, (zoomed.width + pad * Z, (zoomed.height - 128) // 2))
        big.save(f"{prefix}-{theme}-zoom4x.png")
    print("previews written:", prefix)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("cmd")
    p.add_argument("src")
    p.add_argument("dst")
    p.add_argument("--zoom", type=float, default=1.0)
    p.add_argument("--dx", type=int, default=0)
    p.add_argument("--dy", type=int, default=0)
    p.add_argument("--crop", default="none")
    p.add_argument("--small", default=None)
    p.add_argument("--small-max", type=int, default=32)
    p.add_argument("--no-rim", action="store_true")
    args = p.parse_args()
    if args.cmd == "master":
        im, box = build_master(Image.open(args.src), args.zoom, args.dx, args.dy, args.crop,
                               rim=not args.no_rim)
        im.save(args.dst)
        print("master written:", args.dst, "crop box:", box)
    elif args.cmd == "iconset":
        build_iconset(args.src, args.dst, args.small, args.small_max)
    elif args.cmd == "preview":
        build_preview(args.src, args.dst, args.small, args.small_max)
