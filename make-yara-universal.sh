#!/bin/bash
# Produces build/yara-universal: a universal (arm64 + x86_64) libyara_x_capi plus a pkg-config
# file pointing at it, so `swift build --arch arm64 --arch x86_64` links and the bundle runs on
# Intel Macs.
#
# Homebrew on Apple Silicon only ships an arm64 dylib, and VirusTotal publishes no macOS C-API
# artifact, so the x86_64 slice is built from the same tagged source as the installed formula.
# Needs: brew install yara-x cargo-c, and `rustup target add x86_64-apple-darwin`.
# Output is cached; delete build/yara-universal to rebuild (for example after a yara-x upgrade).
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/.cargo/bin:$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"
OUT="$PWD/build/yara-universal"
LIB="$OUT/lib/libyara_x_capi.1.dylib"
[ -f "$LIB" ] && exit 0

ARM_DIR="$(pkg-config --variable=libdir yara_x_capi)"
VERSION="$(pkg-config --modversion yara_x_capi)"
SRC="${YARA_X_SRC:-$PWD/build/yara-x-src}"

if [ ! -d "$SRC" ]; then
    git clone --depth 1 --branch "v$VERSION" https://github.com/VirusTotal/yara-x.git "$SRC"
fi

# The deployment target keeps the x86_64 slice loadable on every macOS the app supports.
MACOSX_DEPLOYMENT_TARGET=11.0 cargo cbuild --manifest-path "$SRC/Cargo.toml" -p yara-x-capi \
    --release --target x86_64-apple-darwin --library-type cdylib --target-dir "$OUT/cargo"

X86="$(find "$OUT/cargo/x86_64-apple-darwin/release" -maxdepth 1 -name 'libyara_x_capi*.dylib' ! -type l | head -1)"
[ -n "$X86" ] || { echo "error: x86_64 libyara_x_capi was not produced" >&2; exit 1; }

mkdir -p "$OUT/lib/pkgconfig" "$OUT/include"
lipo -create "$ARM_DIR/libyara_x_capi.1.dylib" "$X86" -output "$LIB"
# Absolute id so `swift run` can load it during the build; make-app.sh re-points it at the bundle.
install_name_tool -id "$LIB" "$LIB"
# Editing the id invalidates the signature, and arm64 kills unsigned code on load.
codesign --force --sign - "$LIB" >/dev/null 2>&1
ln -sf libyara_x_capi.1.dylib "$OUT/lib/libyara_x_capi.dylib"
cp "$(pkg-config --variable=includedir yara_x_capi)"/yara_x.h "$OUT/include/"

cat > "$OUT/lib/pkgconfig/yara_x_capi.pc" <<EOF
prefix=$OUT
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: yara_x_capi
Description: A C API for the YARA-X library.
Version: $VERSION
Libs: -L\${libdir} -lyara_x_capi
Cflags: -I\${includedir}
EOF

lipo -archs "$LIB"
