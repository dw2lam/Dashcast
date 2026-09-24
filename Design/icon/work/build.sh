#!/usr/bin/env bash
# Build Dashcast icon deliverables from the chosen Codex artwork.
#   build.sh <master-art.png> [small-art.png] [master zoom] [small zoom]
# Writes: Design/icon/AppIcon-1024.png, Design/icon/AppIcon-small-1024.png (if small art),
#         Design/icon/AppIcon.iconset/, Design/AppIcon.icns, Design/icon/preview-*.png
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ICON="$(dirname "$HERE")"
DESIGN="$(dirname "$ICON")"
ART="$1"; SMALL="${2:-}"; MZ="${3:-1.0}"; SZ="${4:-1.0}"

python3 "$HERE/iconkit.py" master "$ART" "$ICON/AppIcon-1024.png" --zoom "$MZ"
SMALLARGS=()
if [[ -n "$SMALL" ]]; then
  python3 "$HERE/iconkit.py" master "$SMALL" "$ICON/AppIcon-small-1024.png" --zoom "$SZ"
  SMALLARGS=(--small "$ICON/AppIcon-small-1024.png")
fi
rm -rf "$ICON/AppIcon.iconset"
python3 "$HERE/iconkit.py" iconset "$ICON/AppIcon-1024.png" "$ICON/AppIcon.iconset" ${SMALLARGS[@]+"${SMALLARGS[@]}"}
iconutil -c icns "$ICON/AppIcon.iconset" -o "$DESIGN/AppIcon.icns"
python3 "$HERE/iconkit.py" preview "$ICON/AppIcon-1024.png" "$ICON/preview" ${SMALLARGS[@]+"${SMALLARGS[@]}"}
ls -la "$DESIGN/AppIcon.icns" "$ICON"/AppIcon-1024.png "$ICON"/preview-*.png
