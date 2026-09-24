#!/usr/bin/env bash
# make-dmg.sh — package Dashcast.app into a drag-to-install disk image.
#
#   scripts/make-dmg.sh                          # build/Dashcast.app -> build/Dashcast.dmg
#   scripts/make-dmg.sh path/to/Some.app         # any .app (staged on the volume as Dashcast.app)
#   scripts/make-dmg.sh path/to/Some.app out.dmg
#
# Env:
#   DMG_BACKGROUND=path.tiff    background (default Design/dmg/background.tiff = 660x400 + @2x)
#   DMG_CODESIGN="Developer ID Application: …"   sign the finished .dmg
#
# Fully headless: hdiutil + a .DS_Store written directly with Python `ds_store` + `mac_alias`
# (the same records Finder itself writes). No AppleScript, no Finder window, nothing on screen,
# so it also runs over SSH / in CI. Python deps are taken from, in order: python3 if it already
# has them -> `uv run --with …` -> a cached venv in ~/.cache/dashcast/dmg-venv.
#
# Layout contract — these numbers are baked into Design/dmg/background.* ; change them together:
#   window content 660 x 400 pt, 128 pt icons, 12 pt labels,
#   Dashcast.app centred at (170,190), /Applications alias centred at (490,190)  [origin top-left]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/Dashcast.app}"
OUT="${2:-$ROOT/build/Dashcast.dmg}"
BACKGROUND="${DMG_BACKGROUND:-$ROOT/Design/dmg/background.tiff}"

VOLNAME="Dashcast"
APP_NAME="Dashcast.app"
CONTENT_W=660
CONTENT_H=400
TITLEBAR_H=32          # macOS 26/27 title bar of a toolbar-less Finder window (window = content + this)
WIN_X=200              # window origin in Finder's bottom-left screen coordinates
WIN_Y=400              #   (top edge ≈150 pt under the top of a 982 pt-tall screen)
ICON_SIZE=128
TEXT_SIZE=12
APP_X=170;  APP_Y=190
APPS_X=490; APPS_Y=190

log() { echo "make-dmg: $*"; }
die() { echo "make-dmg: error: $*" >&2; exit 1; }

[[ "$(uname)" == Darwin ]] || die "macOS only"
[[ -d "$APP" && -f "$APP/Contents/Info.plist" ]] || die "app bundle not found: $APP (build it first, or pass a path)"
[[ -f "$BACKGROUND" ]] || die "background not found: $BACKGROUND"

# ── Python with ds_store + mac_alias ────────────────────────────────────────────────────────
if python3 -c 'import ds_store, mac_alias' 2>/dev/null; then
  PY=(python3)
elif command -v uv >/dev/null 2>&1; then
  PY=(uv run --quiet --no-project --with ds_store --with mac_alias python3)
else
  VENV="${XDG_CACHE_HOME:-$HOME/.cache}/dashcast/dmg-venv"
  if ! "$VENV/bin/python3" -c 'import ds_store, mac_alias' 2>/dev/null; then
    log "installing ds_store + mac_alias into $VENV…"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet ds_store mac_alias
  fi
  PY=("$VENV/bin/python3")
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dashcast-dmg.XXXXXX")"
MOUNT_DIR=""
cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -force -quiet 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── 1. Stage the volume contents ────────────────────────────────────────────────────────────
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME"
BG_NAME="background.${BACKGROUND##*.}"
cp "$BACKGROUND" "$STAGE/.background/$BG_NAME"
ln -s /Applications "$STAGE/Applications"

# ── 2. Writable image, mounted invisibly at a private path ──────────────────────────────────
RW_DMG="$WORK/rw.dmg"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
log "creating ${SIZE_MB} MB read-write image…"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_MB}m" "$RW_DMG"

# Under /Volumes (random name, so a mounted "Dashcast" can't collide) but -nobrowse, so Finder
# never shows it. It must live under /Volumes: the background alias records its path relative
# to the volume root, and a mount elsewhere bakes a bogus "..:..:var:folders:…" fallback path.
MOUNT_DIR="$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse -owners off \
  -mountrandom /Volumes "$RW_DMG" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
[[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]] || die "could not mount $RW_DMG"

# Volume icon = the app's own icon, when the bundle declares one; hide the ".app" extension.
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$STAGE/$APP_NAME/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$ICON_FILE" && "$ICON_FILE" != *.icns ]] && ICON_FILE="$ICON_FILE.icns"
if command -v SetFile >/dev/null 2>&1; then
  if [[ -n "$ICON_FILE" && -f "$STAGE/$APP_NAME/Contents/Resources/$ICON_FILE" ]]; then
    cp "$STAGE/$APP_NAME/Contents/Resources/$ICON_FILE" "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"
    SetFile -a C "$MOUNT_DIR"
  fi
  SetFile -a E "$MOUNT_DIR/$APP_NAME"
else
  log "SetFile not found (Xcode Command Line Tools): skipping volume icon + hidden extension"
fi

# ── 3. Window layout: write the .DS_Store that Finder reads when the volume opens ───────────
log "writing Finder layout…"
"${PY[@]}" - "$MOUNT_DIR" "$APP_NAME" "$BG_NAME" "$WIN_X" "$WIN_Y" "$CONTENT_W" "$((CONTENT_H + TITLEBAR_H))" \
  "$ICON_SIZE" "$TEXT_SIZE" "$APP_X" "$APP_Y" "$APPS_X" "$APPS_Y" <<'PY'
import sys
from ds_store import DSStore
from mac_alias import Alias

mnt, app, bg = sys.argv[1:4]
x, y, w, h, icon, text, ax, ay, bx, by = map(int, sys.argv[4:])

with DSStore.open(f"{mnt}/.DS_Store", "w+") as d:
    d["."]["vSrn"] = ("long", 1)
    d["."]["bwsp"] = {
        "WindowBounds": f"{{{{{x}, {y}}}, {{{w}, {h}}}}}",
        "ShowToolbar": False, "ShowTabView": False, "ShowPathbar": False,
        "ShowStatusBar": False, "ShowSidebar": False, "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
    }
    d["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,  # picture
        "backgroundImageAlias": Alias.for_file(f"{mnt}/.background/{bg}").to_bytes(),
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "iconSize": float(icon), "textSize": float(text), "axTextSize": float(text),
        "labelOnBottom": True, "arrangeBy": "none", "gridSpacing": 100.0,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0,
        "showItemInfo": False, "showIconPreview": False,
    }
    d[app]["Iloc"] = (ax, ay)  # icon centres, window-content coordinates
    d["Applications"]["Iloc"] = (bx, by)
PY

# ── 4. Seal: tidy, detach, compress ─────────────────────────────────────────────────────────
rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync
for i in 1 2 3 4 5; do
  hdiutil detach "$MOUNT_DIR" -quiet && break
  [[ $i == 5 ]] && hdiutil detach "$MOUNT_DIR" -force -quiet
  sleep 2
done
MOUNT_DIR=""

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
log "compressing (UDZO)…"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT"

if [[ -n "${DMG_CODESIGN:-}" ]]; then
  codesign --force --sign "$DMG_CODESIGN" --timestamp "$OUT"
fi
hdiutil verify -quiet "$OUT"
log "wrote $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
