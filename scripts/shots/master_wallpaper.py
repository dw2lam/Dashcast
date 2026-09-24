"""Upscales a generated wallpaper to a 5K master (5120x3200) plus web copies.

    python3 master_wallpaper.py <in.png> <out-5k.png> [web.jpg ...]

The generated art is softened first (its frosted texture turns blotchy when enlarged), upscaled
with Lanczos, the glass rims re-crisped with a wide low-amount unsharp mask, and fine luminance
grain added at full size so the big gradients never band.
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

W, H = 5120, 3200
src = Image.open(sys.argv[1]).convert("RGB").filter(ImageFilter.GaussianBlur(0.9))
scale = max(W / src.width, H / src.height)
up = src.resize((round(src.width * scale), round(src.height * scale)), Image.LANCZOS)
left, top = (up.width - W) // 2, (up.height - H) // 2
up = up.crop((left, top, left + W, top + H))
up = up.filter(ImageFilter.UnsharpMask(radius=6, percent=35, threshold=6))
rng = np.random.default_rng(7)
arr = np.asarray(up).astype(np.float32)
grain = rng.normal(0, 1.6, (H, W, 1)).astype(np.float32)
arr = np.clip(arr + grain, 0, 255).astype(np.uint8)
master = Image.fromarray(arr)
master.save(sys.argv[2], optimize=True)
for path in sys.argv[3:]:
    size = (2560, 1600)
    master.resize(size, Image.LANCZOS).save(path, quality=90, optimize=True, progressive=True, subsampling=0)
print("ok", master.size)
