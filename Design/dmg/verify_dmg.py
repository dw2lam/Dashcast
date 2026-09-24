#!/usr/bin/env python3
"""Verify a Dashcast DMG's Finder layout headlessly — no Finder window, no screen capture.

    uv run --no-project --with ds_store --with mac_alias --with pillow \
        python3 Design/dmg/verify_dmg.py build/Dashcast.dmg [preview.png]

Mounts the image invisibly (-nobrowse -noautoopen, private mount point), then:
  * dumps the volume's .DS_Store (bwsp window, icvp view options, Iloc icon centres),
  * checks the background alias resolves the way Finder resolves it (volume name + file IDs),
  * checks .background/background.tiff carries both the 1x and the @2x representation,
  * renders what Finder will draw — the shipped @2x background, the app's real icon and the
    Applications-folder alias at their recorded positions, plus Finder's black 12 pt labels —
    to a PNG (default: Design/dmg/preview/dmg-layout-composite.png),
and detaches. Exit status is non-zero if any check fails.
"""
from __future__ import annotations

import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile

from ds_store import DSStore
import ds_store.store as _st
from mac_alias import Alias
from PIL import Image, ImageDraw, ImageFont

_st.codecs.pop(b"pBBk", None)            # tolerate Finder-written bookmark blobs (keep them raw)

HERE = pathlib.Path(__file__).resolve().parent
CORETYPES = pathlib.Path("/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources")
EXPECT = {"window": (660, 400), "titlebar": 32, "icon": 128, "text": 12,
          "Iloc": {"Dashcast.app": (170, 190), "Applications": (490, 190)}}
LABEL_Y = 272                            # measured centre of Finder's label line (content coords)
S = 2


def icns(path: pathlib.Path, px: int) -> Image.Image:
    im = Image.open(path)
    w, h, scale = max(im.info.get("sizes", []), key=lambda s: (s[0] * s[2] == px, s[0] * s[2]))
    im.size = (w, h)
    im.load(scale=scale)
    return im.convert("RGBA").resize((px, px), Image.LANCZOS)


def sf(px: int) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", px)
    f.set_variation_by_axes([100, 17, 400, 400])
    return f


def main() -> int:
    dmg = pathlib.Path(sys.argv[1]).resolve()
    out = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else HERE / "preview" / "dmg-layout-composite.png"
    failures: list[str] = []

    def check(ok: bool, what: str) -> None:
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            failures.append(what)

    mnt = pathlib.Path(tempfile.mkdtemp(prefix="dashcast-verify."))
    subprocess.run(["hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen", "-noverify",
                    "-mountpoint", str(mnt), str(dmg)], check=True)
    try:
        print(f"volume contents: {sorted(os.listdir(mnt))}")
        with DSStore.open(str(mnt / ".DS_Store"), "r") as d:
            recs = {(e.filename, e.code.decode()): e.value for e in d}
        bwsp, icvp = recs[(".", "bwsp")], recs[(".", "icvp")]
        print("bwsp:", {k: v for k, v in bwsp.items()})
        print("icvp:", {k: v for k, v in icvp.items() if k != "backgroundImageAlias"})

        w, h = EXPECT["window"]
        bounds = bwsp["WindowBounds"].replace("{", "").replace("}", "").split(",")
        check([int(float(v)) for v in bounds[2:]] == [w, h + EXPECT["titlebar"]],
              f"window {bounds[2].strip()} x {bounds[3].strip()} = {w} x {h} content + title bar")
        check(not any(bwsp.get(k) for k in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView")),
              "toolbar / sidebar / status bar / path bar / tab bar hidden")
        check(icvp["iconSize"] == EXPECT["icon"] and icvp["textSize"] == EXPECT["text"] and icvp["labelOnBottom"],
              f"icon size {icvp['iconSize']:.0f}, text {icvp['textSize']:.0f} pt, labels below")
        check(icvp["backgroundType"] == 2 and icvp["arrangeBy"] == "none", "picture background, free arrangement")
        for name, pos in EXPECT["Iloc"].items():
            got = tuple(recs.get((name, "Iloc"), ()))
            check(got == pos, f"{name} centred at {got} (want {pos})")

        # Background alias: Finder resolves by volume, then file IDs (HFS+ CNID == st_ino).
        a = Alias.from_bytes(icvp["backgroundImageAlias"])
        bg = mnt / ".background" / a.target.filename
        check(a.volume.name == "Dashcast", f"alias volume name {a.volume.name!r}")
        check(bg.is_file() and a.target.cnid == bg.stat().st_ino and a.target.folder_cnid == bg.parent.stat().st_ino,
              f"alias -> /.background/{a.target.filename} (file id {a.target.cnid}, folder id {a.target.folder_cnid})")
        info = subprocess.run(["tiffutil", "-info", str(bg)], capture_output=True, text=True).stdout
        sizes = sorted({line.split(":")[1].strip() for line in info.splitlines() if "Image Width" in line})
        tiff = Image.open(bg)
        reps = []
        for i in range(getattr(tiff, "n_frames", 1)):
            tiff.seek(i)
            reps.append(tiff.size)
        check(sorted(reps) == [(w, h), (w * 2, h * 2)], f"background.tiff representations {reps}")

        # Composite what Finder draws, at @2x.
        tiff.seek(reps.index((w * 2, h * 2)))
        canvas = tiff.convert("RGBA")
        app = mnt / "Dashcast.app"
        icon_file = plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIconFile", "AppIcon")
        icon_file += "" if icon_file.endswith(".icns") else ".icns"
        px = EXPECT["icon"] * S
        icons = {
            "Dashcast.app": icns(app / "Contents/Resources" / icon_file, px),
            "Applications": icns(CORETYPES / "ApplicationsFolderIcon.icns", px),
        }
        badge = icns(CORETYPES / "AliasBadgeIcon.icns", px)
        icons["Applications"].alpha_composite(badge)
        hidden_ext = subprocess.run(["GetFileInfo", "-aE", str(app)], capture_output=True, text=True).stdout.strip() == "1"
        check(hidden_ext, "Dashcast.app has its extension hidden (label reads 'Dashcast')")
        draw = ImageDraw.Draw(canvas)
        for name, (cx, cy) in EXPECT["Iloc"].items():
            canvas.alpha_composite(icons[name], (cx * S - px // 2, cy * S - px // 2))
            label = "Dashcast" if (name == "Dashcast.app" and hidden_ext) else name
            draw.text((cx * S, LABEL_Y * S), label, font=sf(EXPECT["text"] * S), fill=(0, 0, 0, 255), anchor="mm")
        out.parent.mkdir(parents=True, exist_ok=True)
        canvas.convert("RGB").save(out)
        tiff.close()
        print(f"composite: {out}")
    finally:
        if subprocess.run(["hdiutil", "detach", "-quiet", str(mnt)], check=False).returncode:
            subprocess.run(["hdiutil", "detach", "-quiet", "-force", str(mnt)], check=False)
        try:
            mnt.rmdir()
        except OSError:
            pass
    print("RESULT:", "PASS" if not failures else f"FAIL ({len(failures)})")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
