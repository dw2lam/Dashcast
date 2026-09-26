#!/usr/bin/env python3
"""Contact sheet: grade_sheet.py out.png ref img1 img2 ... (each fitted to 700×470, side by side, labelled)."""
import sys
from PIL import Image, ImageDraw

out, *paths = sys.argv[1:]
ims = []
for p in paths:
    im = Image.open(p).convert('RGB')
    im.thumbnail((700, 470))
    ims.append((p.split('/')[-1], im))
W = sum(i.width for _, i in ims) + 10 * (len(ims) - 1)
H = max(i.height for _, i in ims) + 22
sheet = Image.new('RGB', (W, H), (128, 128, 128))
d = ImageDraw.Draw(sheet)
x = 0
for name, im in ims:
    sheet.paste(im, (x, 22))
    d.text((x + 4, 4), name, fill=(255, 255, 255))
    x += im.width + 10
sheet.save(out)
