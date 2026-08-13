#!/bin/bash
# Assembles Sweep.app from the SwiftPM executable.
#
# SwiftPM builds a bare Mach-O; macOS needs a bundle for the menu bar, window activation,
# and — importantly for this app — a stable identity that TCC can attach a Full Disk Access
# grant to. Re-signing with a different identity resets that grant, which is why the ad-hoc
# signature below is applied deterministically.
set -euo pipefail

CONFIG="${1:-release}"
cd "$(dirname "$0")"

swift build -c "$CONFIG"
# Regenerate the icon from SweepMark so the shipped asset can never drift from the source.
swift run -c "$CONFIG" MakeIcon Resources >/dev/null
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SweepApp"
APP="build/Sweep.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sweep"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Sweep.icns "$APP/Contents/Resources/Sweep.icns"

# Bundle YARA-X (BSD-3-Clause) so the shipped app does not depend on Homebrew being installed
# on the machine that runs it. The library is re-pointed at the bundle and re-signed with the
# app's own identity below, which is what lets it load under the Hardened Runtime's library
# validation.
YARA_LIB="$(pkg-config --variable=libdir yara_x_capi 2>/dev/null || echo "$(brew --prefix)/lib")/libyara_x_capi.1.dylib"
if [ ! -f "$YARA_LIB" ]; then
    echo "error: libyara_x_capi.1.dylib not found. Install it with: brew install yara-x" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
cp "$YARA_LIB" "$APP/Contents/Frameworks/libyara_x_capi.1.dylib"
chmod u+w "$APP/Contents/Frameworks/libyara_x_capi.1.dylib"
install_name_tool -id "@rpath/libyara_x_capi.1.dylib" \
    "$APP/Contents/Frameworks/libyara_x_capi.1.dylib"
install_name_tool -change "$(otool -D "$YARA_LIB" | tail -1)" "@rpath/libyara_x_capi.1.dylib" \
    "$APP/Contents/MacOS/Sweep"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Sweep"

# Signing identity comes from the environment, never from the file, so a public build script
# carries no account details and an unconfigured checkout still produces a runnable app.
#
# SWEEP_SIGN_ID unset  -> ad-hoc: runs locally, keeps a stable bundle identity, but Gatekeeper
#                         rejects it once downloaded.
# SWEEP_SIGN_ID set    -> Developer ID, with Hardened Runtime and a secure timestamp, both of
#                         which notarization refuses builds without.
#
# No entitlements file is passed, deliberately. Sweep needs no Hardened Runtime exceptions: it
# has no JIT, no unsigned executable memory and no dyld interposing. It does load one
# third-party library (YARA-X), but that library is bundled and re-signed with this same
# identity, so library validation accepts it without a disable-library-validation exception —
# which is why no entitlement is needed even now. Access to the user's files is governed by
# TCC, which is not an entitlement — the
# sandbox file entitlements would only matter to a sandboxed app, and Sweep is not one (see
# docs/DEPLOYMENT.md on why the App Store is not the channel for this product). An entitlements
# plist here would be a file granting nothing, and a reviewer would have to read it to find
# that out.
if [ -n "${SWEEP_SIGN_ID:-}" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$SWEEP_SIGN_ID" "$APP/Contents/Frameworks/libyara_x_capi.1.dylib"
    codesign --force --options runtime --timestamp \
        --sign "$SWEEP_SIGN_ID" --identifier com.sweep.app "$APP"
    echo "Built $APP (signed: $SWEEP_SIGN_ID)"
else
    codesign --force --sign - "$APP/Contents/Frameworks/libyara_x_capi.1.dylib" >/dev/null 2>&1
    codesign --force --sign - --identifier com.sweep.app "$APP" >/dev/null 2>&1
    echo "Built $APP (ad-hoc — set SWEEP_SIGN_ID for a distributable signature)"
fi
