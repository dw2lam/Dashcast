#!/usr/bin/env bash
# Builds build/Dashcast.app — web client, release binary, Info.plist, resources — and signs it.
#
#   scripts/build-app.sh
#
# Environment:
#   SKIP_WEB=1               reuse the existing Web/dist
#   DASHCAST_REAL=1|0        force the real-service wiring on/off (default: on once DashcastService,
#                            StreamEngine and NetworkManager exist)
#   DASHCAST_RTC=1|0         force WebRTC wiring on/off (default: on once DataChannelPeerFactory exists)
#   DASHCAST_BINARY=path     package this prebuilt binary instead of running `swift build`
#   SIGN_IDENTITY=...        codesigning identity ("-" = ad hoc; default: contents of .sign-identity)
#   APP_PATH / BUNDLE_ID     build a separate copy elsewhere (e.g. scripts/shots/capture.sh's shots app)
#   VERSION / BUILD_NUMBER   CFBundleShortVersionString / CFBundleVersion
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Dashcast"
BUNDLE_ID="${BUNDLE_ID:-online.davidlam.dashcast}"
VERSION="${VERSION:-0.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}"
# A stable identity keeps the Screen Recording / Accessibility grants across rebuilds. Put yours in
# .sign-identity (git-ignored), e.g. "Apple Development: you@example.com (TEAMID)"; otherwise ad hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(cat "$ROOT/.sign-identity" 2>/dev/null || echo -)}"
SCRATCH="$ROOT/.build/app"
APP="${APP_PATH:-$ROOT/build/$APP_NAME.app}"
CONTENTS="$APP/Contents"

step() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

# 1. Web client ---------------------------------------------------------------
if [[ "${SKIP_WEB:-0}" == 1 ]]; then
    warn "SKIP_WEB=1 — packaging the existing Web/dist"
elif [[ -f Web/package.json ]]; then
    step "Building the web client"
    if [[ ! -d Web/node_modules ]]; then
        if [[ -f Web/package-lock.json ]]; then npm --prefix Web ci --no-audit --no-fund
        else npm --prefix Web install --no-audit --no-fund; fi
    fi
    npm --prefix Web run build
else
    warn "Web/package.json not found — skipping the web client build"
fi

# 2. Swift --------------------------------------------------------------------
if [[ -x scripts/build-libdatachannel.sh ]]; then
    step "Ensuring libdatachannel (no-op when up to date)"
    scripts/build-libdatachannel.sh >/dev/null
fi
SWIFT_FLAGS=()
real_types_present() {
    grep -rEqs 'class[[:space:]]+DashcastService[^[:alnum:]_]' Sources/DashcastServer &&
    grep -rEqs 'class[[:space:]]+StreamEngine[^[:alnum:]_]' Sources/DashcastStream &&
    grep -rEqs 'class[[:space:]]+NetworkManager[^[:alnum:]_]' Sources/DashcastNetwork
}
rtc_types_present() {
    grep -rEqs 'rtc:[[:space:]]*(any[[:space:]]+)?RTCPeerFactory' Sources/DashcastServer &&
    grep -rEqs 'class[[:space:]]+DataChannelPeerFactory[^[:alnum:]_]' Sources/DashcastRTC
}
REAL="${DASHCAST_REAL:-auto}"
if [[ "$REAL" == auto ]]; then real_types_present && REAL=1 || REAL=0; fi
if [[ "$REAL" == 1 ]]; then
    SWIFT_FLAGS+=(-Xswiftc -DDASHCAST_REAL)
    RTC="${DASHCAST_RTC:-auto}"
    if [[ "$RTC" == auto ]]; then rtc_types_present && RTC=1 || RTC=0; fi
    if [[ "$RTC" == 1 ]]; then
        SWIFT_FLAGS+=(-Xswiftc -DDASHCAST_RTC)
    else
        warn "DataChannelPeerFactory not found — real service without WebRTC (secure mode only)"
    fi
else
    warn "real service types not all present — building with the mock service (DASHCAST_REAL=1 forces)"
fi

if [[ -n "${DASHCAST_BINARY:-}" ]]; then
    step "Using prebuilt binary $DASHCAST_BINARY"
    BINARY="$DASHCAST_BINARY"
    BIN_DIR="$(dirname "$BINARY")"
else
    FLAG_NAMES="$(printf '%s\n' ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} | sed -n 's/^-D//p' | paste -sd, -)"
    step "Building $APP_NAME (release${FLAG_NAMES:+, $FLAG_NAMES})"
    swift build -c release --product "$APP_NAME" --scratch-path "$SCRATCH" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}
    BIN_DIR="$(swift build -c release --product "$APP_NAME" --scratch-path "$SCRATCH" --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})"
    BINARY="$BIN_DIR/$APP_NAME"
fi

# 3. Bundle -------------------------------------------------------------------
step "Assembling ${APP#"$ROOT"/}"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
# SwiftPM stamps LC_BUILD_VERSION's SDK with the deployment target (15.0), which makes macOS 26+
# run the app in the legacy (pre-Liquid Glass) compatibility appearance. Stamp the real SDK.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace -output "$CONTENTS/MacOS/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp Resources/Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Non-system dylibs the binary links (e.g. a vendored libdatachannel.dylib) → Contents/Frameworks.
bundle_dylibs() {
    local target="$1" dep name src
    while read -r dep; do
        case "$dep" in /usr/lib/*|/System/*|@executable_path/*|@loader_path/*) continue ;; esac
        name="$(basename "$dep")"
        [[ -e "$CONTENTS/Frameworks/$name" ]] && { install_name_tool -change "$dep" "@rpath/$name" "$target"; continue; }
        src=""
        if [[ "$dep" == @rpath/* ]]; then
            for dir in "$BIN_DIR" Vendor/*/lib; do
                [[ -e "$dir/$name" ]] && { src="$dir/$name"; break; }
            done
        elif [[ -e "$dep" ]]; then
            src="$dep"
        fi
        if [[ -z "$src" ]]; then warn "can't find $dep to bundle"; continue; fi
        mkdir -p "$CONTENTS/Frameworks"
        cp -L "$src" "$CONTENTS/Frameworks/$name"
        chmod u+w "$CONTENTS/Frameworks/$name"
        install_name_tool -id "@rpath/$name" "$CONTENTS/Frameworks/$name"
        install_name_tool -change "$dep" "@rpath/$name" "$target"
        bundle_dylibs "$CONTENTS/Frameworks/$name"
    done < <(otool -L "$target" | tail -n +2 | awk '{print $1}' | grep -v "^$(basename "$target")")
}
bundle_dylibs "$CONTENTS/MacOS/$APP_NAME"
if [[ -d "$CONTENTS/Frameworks" ]]; then
    otool -l "$CONTENTS/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks" ||
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/$APP_NAME"
    step "Bundled $(ls "$CONTENTS/Frameworks" | tr '\n' ' ')"
fi

# SwiftPM resource bundles, if any target declares resources.
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] && cp -R "$bundle" "$CONTENTS/Resources/"
done

if [[ -d Web/dist ]]; then
    mkdir -p "$CONTENTS/Resources/client"
    cp -R Web/dist/. "$CONTENTS/Resources/client/"
else
    warn "Web/dist not found — the bundle has no car client"
fi

BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [[ -n "$BREW_PREFIX" && -x "$BREW_PREFIX/bin/lego" ]]; then
    mkdir -p "$CONTENTS/Resources/bin"
    cp "$BREW_PREFIX/bin/lego" "$CONTENTS/Resources/bin/lego"
else
    warn "lego not found (brew install lego) — certificate provisioning won't be bundled"
fi

if [[ -f Design/AppIcon.icns ]]; then
    cp Design/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
else
    warn "Design/AppIcon.icns not found — the app uses the generic icon"
fi

# 4. Sign ---------------------------------------------------------------------
if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
    warn "signing identity \"$SIGN_IDENTITY\" not found — signing ad hoc (permission grants won't survive rebuilds)"
    SIGN_IDENTITY="-"
fi
step "Signing with ${SIGN_IDENTITY}"
for nested in "$CONTENTS/Resources/bin/lego" "$CONTENTS"/Frameworks/*; do
    [[ -e "$nested" ]] && codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$nested"
done
# No sandbox; hardened runtime (--options runtime) deliberately off for now.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --identifier "$BUNDLE_ID" \
    --entitlements Resources/Dashcast.entitlements \
    "$APP"
codesign --verify --strict "$APP"

step "Built ${APP#"$ROOT"/} ($VERSION, build $BUILD_NUMBER)"
