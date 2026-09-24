#!/usr/bin/env bash
# Builds libdatachannel (WebRTC: libjuice ICE, usrsctp, libsrtp, DTLS via Mbed TLS) as ONE static
# library for the DashcastRTC module:
#
#   Vendor/libdatachannel/lib/libdatachannel.a      merged: datachannel + juice + usrsctp + srtp2 + mbedtls
#   Vendor/libdatachannel/include/rtc/*.h           full C/C++ headers
#   Sources/CDataChannel/include/rtc/{rtc,version}.h  the C API, imported into Swift via CDataChannel.h
#
#   scripts/build-libdatachannel.sh            # no-op when the output matches the pinned inputs
#   FORCE=1 scripts/build-libdatachannel.sh    # rebuild from scratch
#
# Why Mbed TLS, not OpenSSL: Homebrew's openssl@3 bottles are built for the host macOS
# (minos 26.0 here), which would silently raise the app's floor above macOS 15. Mbed TLS is small,
# builds from a pinned tag in ~20 s with the right deployment target, and needs no dylibs.
#
# Local patches (Vendor/patches/libdatachannel-*.patch) are applied on top of the pinned tag:
#   0001-sr-ntp-anchor               RTCP SR NTP time derived from the RTP timestamp (A/V sync from
#                                    capture pts): new C call rtcSetTrackSenderReportNtpAnchor.
#   0002-media-interceptor-forward   upstream bug: rtcSetMediaInterceptorCallback dispatched null
#                                    messages (crash). Only the loopback test's receiver uses it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LIBDATACHANNEL_REPO="https://github.com/paullouisageneau/libdatachannel.git"
LIBDATACHANNEL_TAG="v0.24.5"
MBEDTLS_REPO="https://github.com/Mbed-TLS/mbedtls.git"
MBEDTLS_TAG="v3.6.7"
DEPLOYMENT_TARGET="15.0"
ARCH="arm64"

VENDOR="$ROOT/Vendor"
SRC="$VENDOR/src"
BUILD="$VENDOR/build"
STAGE="$BUILD/stage"               # mbedtls install prefix (static libs + headers)
OUT="$VENDOR/libdatachannel"
SHIM_INCLUDE="$ROOT/Sources/CDataChannel/include"
PATCHES=("$VENDOR"/patches/libdatachannel-*.patch)
STAMP="$OUT/.stamp"

step() { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
JOBS="$(sysctl -n hw.ncpu)"

# Everything that should trigger a rebuild when it changes.
fingerprint() {
    {
        echo "$LIBDATACHANNEL_TAG $MBEDTLS_TAG $DEPLOYMENT_TARGET $ARCH"
        cat "${PATCHES[@]}"
        cat "${BASH_SOURCE[0]}"
    } | shasum -a 256 | cut -d' ' -f1
}

if [[ "${FORCE:-0}" != 1 && -f "$STAMP" && -f "$OUT/lib/libdatachannel.a" &&
      -f "$SHIM_INCLUDE/rtc/rtc.h" && "$(cat "$STAMP")" == "$(fingerprint)" ]]; then
    echo "libdatachannel $LIBDATACHANNEL_TAG is up to date ($OUT)"
    exit 0
fi

# Tools -----------------------------------------------------------------------
if ! command -v cmake >/dev/null; then
    command -v brew >/dev/null || die "cmake not found (install it, e.g. brew install cmake)"
    step "Installing cmake (Homebrew)"
    brew install cmake
fi
command -v git >/dev/null || die "git not found"
command -v python3 >/dev/null || die "python3 not found (needed for mbedtls scripts/config.py)"

# Sources ---------------------------------------------------------------------
# checkout <repo> <tag> <dir>: shallow clone with submodules; reused when already at <tag>.
# (A marker file, because `git describe` can't see annotated tags in shallow clones.)
checkout() {
    local repo="$1" tag="$2" dir="$3"
    if [[ "${FORCE:-0}" != 1 && -d "$dir/.git" && "$(cat "$dir/.dashcast-tag" 2>/dev/null)" == "$tag" ]]; then
        return
    fi
    step "Cloning $(basename "$dir") $tag"
    rm -rf "$dir"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" \
        --recursive --shallow-submodules "$repo" "$dir"
    echo "$tag" > "$dir/.dashcast-tag"
}

# run <log name> <command...>: quiet unless it fails.
run() {
    local log="$BUILD/logs/$1.log"; shift
    mkdir -p "$BUILD/logs"
    if ! "$@" >"$log" 2>&1; then
        tail -40 "$log" >&2
        die "failed: $* (full log: $log)"
    fi
}

mkdir -p "$SRC" "$BUILD"
checkout "$MBEDTLS_REPO" "$MBEDTLS_TAG" "$SRC/mbedtls"
checkout "$LIBDATACHANNEL_REPO" "$LIBDATACHANNEL_TAG" "$SRC/libdatachannel"

for patch in "${PATCHES[@]}"; do
    [[ -f "$patch" ]] || continue
    if git -C "$SRC/libdatachannel" apply --reverse --check "$patch" 2>/dev/null; then
        continue  # already applied
    fi
    step "Applying $(basename "$patch")"
    git -C "$SRC/libdatachannel" apply "$patch"
done

COMMON_CMAKE=(
    -G "Unix Makefiles"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections"
    -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections"
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON   # never pick up Homebrew's mbedtls via pkg-config
)

# Mbed TLS --------------------------------------------------------------------
step "Building Mbed TLS $MBEDTLS_TAG (static, $ARCH, macOS $DEPLOYMENT_TARGET)"
(
    cd "$SRC/mbedtls"
    # libdatachannel needs DTLS-SRTP key export; DTLS contexts live on several threads.
    python3 scripts/config.py set MBEDTLS_SSL_DTLS_SRTP
    python3 scripts/config.py set MBEDTLS_THREADING_C
    python3 scripts/config.py set MBEDTLS_THREADING_PTHREAD
)
rm -rf "$BUILD/mbedtls" "$STAGE"
run mbedtls-configure cmake -S "$SRC/mbedtls" -B "$BUILD/mbedtls" "${COMMON_CMAKE[@]}" \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DGEN_FILES=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DMBEDTLS_FATAL_WARNINGS=OFF
run mbedtls-build cmake --build "$BUILD/mbedtls" --parallel "$JOBS"
run mbedtls-install cmake --install "$BUILD/mbedtls"

# libdatachannel ----------------------------------------------------------------
step "Building libdatachannel $LIBDATACHANNEL_TAG (static, media on, websocket off)"
rm -rf "$BUILD/libdatachannel"
run libdatachannel-configure cmake -S "$SRC/libdatachannel" -B "$BUILD/libdatachannel" "${COMMON_CMAKE[@]}" \
    -DCMAKE_PREFIX_PATH="$STAGE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DUSE_MBEDTLS=ON \
    -DNO_EXAMPLES=ON -DNO_TESTS=ON -DNO_WEBSOCKET=ON \
    -DMbedTLS_INCLUDE_DIR="$STAGE/include" \
    -DMbedTLS_LIBRARY="$STAGE/lib/libmbedtls.a" \
    -DMbedCrypto_LIBRARY="$STAGE/lib/libmbedcrypto.a" \
    -DMbedX509_LIBRARY="$STAGE/lib/libmbedx509.a" \
    -DMBEDTLS_INCLUDE_DIRS="$STAGE/include" \
    -DMBEDTLS_LIBRARY="$STAGE/lib/libmbedtls.a" \
    -DMBEDCRYPTO_LIBRARY="$STAGE/lib/libmbedcrypto.a" \
    -DMBEDX509_LIBRARY="$STAGE/lib/libmbedx509.a"
run libdatachannel-build cmake --build "$BUILD/libdatachannel" --target datachannel-static --parallel "$JOBS"

# Collect + merge -----------------------------------------------------------------
step "Merging static libraries"
LIBS=(
    "$BUILD/libdatachannel/libdatachannel-static.a"
    "$BUILD/libdatachannel/deps/libjuice/libjuice-static.a"
    "$BUILD/libdatachannel/deps/usrsctp/usrsctplib/libusrsctp.a"
    "$BUILD/libdatachannel/deps/libsrtp/libsrtp2.a"
    "$STAGE/lib/libmbedtls.a"
    "$STAGE/lib/libmbedx509.a"
    "$STAGE/lib/libmbedcrypto.a"
)
for lib in "${LIBS[@]}"; do [[ -f "$lib" ]] || die "missing $lib"; done
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
# Apple libtool keeps same-named members from different archives (e.g. two "error.o").
libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libdatachannel.a" "${LIBS[@]}" 2>&1 |
    grep -v 'same member name' || true

cp -R "$SRC/libdatachannel/include/rtc" "$OUT/include/"
mkdir -p "$SHIM_INCLUDE/rtc"
cp "$OUT/include/rtc/rtc.h" "$OUT/include/rtc/version.h" "$SHIM_INCLUDE/rtc/"

# Sanity: every object is arm64 and built for the deployment target, nothing needs a dylib.
# (Output captured first: `grep -q` closing a pipe early trips pipefail.)
archs="$(lipo -archs "$OUT/lib/libdatachannel.a")"
[[ "$archs" == "$ARCH" ]] || die "merged library is '$archs', expected $ARCH"
minos="$(otool -l "$OUT/lib/libdatachannel.a" | awk '/ minos / {print $2}' | sort -u | tr '\n' ' ')"
[[ "$minos" == "$DEPLOYMENT_TARGET " ]] || die "objects built for macOS '$minos', expected $DEPLOYMENT_TARGET"
symbols="$(nm -g "$OUT/lib/libdatachannel.a" 2>/dev/null)"
[[ "$symbols" == *" T _rtcSetTrackSenderReportNtpAnchor"* ]] || die "patched rtcSetTrackSenderReportNtpAnchor missing"

{
    echo "libdatachannel $LIBDATACHANNEL_TAG + $(printf '%s ' "${PATCHES[@]##*/}")"
    echo "mbedtls $MBEDTLS_TAG, $ARCH, macOS $DEPLOYMENT_TARGET"
    for lib in "${LIBS[@]}"; do printf '  %8d KB  %s\n' "$(( $(stat -f %z "$lib") / 1024 ))" "${lib#"$VENDOR/"}"; done
    printf '  %8d KB  merged libdatachannel.a\n' "$(( $(stat -f %z "$OUT/lib/libdatachannel.a") / 1024 ))"
} | tee "$OUT/BUILD-INFO.txt"
fingerprint > "$STAMP"
step "Done: $OUT"
