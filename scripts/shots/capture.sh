#!/usr/bin/env bash
# Native macOS window screenshots of every screen, light and dark, for the website.
#
#   scripts/shots/capture.sh [out-dir]          (default: website/shots-raw/captures)
#   SCENES=main,guide APPEARANCES=dark NO_BUILD=1 scripts/shots/capture.sh
#
# - Builds a separate "build/shots/Dashcast Shots.app" (bundle id online.davidlam.dashcast.shots),
#   so the shots never touch the real app's defaults, window frames, status item or binary.
# - Stages the windows on a private HiDPI virtual display (vdisplay.swift) with its own desktop
#   picture, parked off the corner of the built-in display: nothing appears on the real screen.
# - The app (DASHCAST_SHOT, Sources/Dashcast/App/ShotMode.swift) captures each window with
#   `screencapture -x -l`, activating only for a sub-second burst per capture and handing focus
#   straight back. It is run directly (not with `open`), so screencapture inherits this terminal's
#   Screen Recording permission instead of prompting for a new one.
# - Then scripts/shots/process.py turns the raw PNGs into the website's WebP set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/shots"
OUT="${1:-$ROOT/website/shots-raw/captures}"
APP="$ROOT/build/shots/Dashcast Shots.app"
BUNDLE_ID="online.davidlam.dashcast.shots"
VDISPLAY="$ROOT/build/shots/vdisplay"
SCENES="${SCENES:-1}"
APPEARANCES="${APPEARANCES:-dark light}"
WALLPAPER_dark="${WALLPAPER_DARK:-$ROOT/website/shots-raw/wallpaper-dark-5k.png}"
WALLPAPER_light="${WALLPAPER_LIGHT:-$ROOT/website/shots-raw/wallpaper-light-5k.png}"

step() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

if [[ "${NO_BUILD:-0}" != 1 ]]; then
    step "Building the shots app"
    SKIP_WEB=1 APP_PATH="$APP" BUNDLE_ID="$BUNDLE_ID" "$ROOT/scripts/build-app.sh" >/dev/null
fi
if [[ ! -x "$VDISPLAY" || "$HERE/vdisplay.swift" -nt "$VDISPLAY" ]]; then
    step "Building vdisplay"
    mkdir -p "$(dirname "$VDISPLAY")"
    swiftc -O -parse-as-library -import-objc-header "$ROOT/Sources/CVirtualDisplay/include/CVirtualDisplay.h" \
        "$HERE/vdisplay.swift" -o "$VDISPLAY" -framework AppKit -framework CoreGraphics
fi

# A clean, first-run-free defaults domain; the status item is only inserted for the menu scene.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" onboardingComplete -bool true
defaults write "$BUNDLE_ID" showMenuBarIcon -bool false
defaults write "$BUNDLE_ID" menuBarOnly -bool false

mkdir -p "$OUT"
WORK="$(mktemp -d)"
mkfifo "$WORK/commands"
"$VDISPLAY" --width 2560 --height 1600 < "$WORK/commands" > "$WORK/vdisplay.log" 2>&1 &
VDISPLAY_PID=$!
exec 3> "$WORK/commands"
cleanup() {
    echo quit >&3 2>/dev/null || true
    exec 3>&- || true
    wait "$VDISPLAY_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

for _ in {1..100}; do
    grep -q '^display ' "$WORK/vdisplay.log" && break
    grep -q '^error' "$WORK/vdisplay.log" && break
    sleep 0.1
done
DISPLAY_LINE="$(grep '^display ' "$WORK/vdisplay.log" || true)"
if [[ -z "$DISPLAY_LINE" ]]; then
    cat "$WORK/vdisplay.log" >&2
    exit 1
fi
DISPLAY_ID="$(awk '{print $2}' <<<"$DISPLAY_LINE")"
step "Stage display $DISPLAY_LINE"

for appearance in $APPEARANCES; do
    wallpaper_var="WALLPAPER_$appearance"
    echo "wallpaper ${!wallpaper_var}" >&3
    sleep 2
    step "Capturing $appearance"
    env DASHCAST_MOCK=1 DASHCAST_MOCK_PHASE=streaming DASHCAST_MOCK_CERT=1 DASHCAST_MOCK_TOPOLOGY=macHotspot \
        DASHCAST_APPEARANCE="$appearance" DASHCAST_SHOT="$SCENES" DASHCAST_SHOT_DISPLAY="$DISPLAY_ID" \
        DASHCAST_SHOT_OUT="$OUT" DASHCAST_SHOT_PREFIX="$appearance" \
        "$APP/Contents/MacOS/Dashcast" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO 2>&1 \
        | grep --line-buffered '^\[shots\]' || true
done

step "Raw captures in ${OUT#"$ROOT"/}"
