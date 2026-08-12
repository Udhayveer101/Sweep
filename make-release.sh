#!/bin/bash
# Builds, signs, notarizes, staples and verifies a distributable Sweep release.
#
#   SWEEP_SIGN_ID="Developer ID Application: Name (TEAMID)" \
#   SWEEP_NOTARY_PROFILE=sweep-notary \
#   ./make-release.sh
#
# Credentials are never stored here. SWEEP_NOTARY_PROFILE names a keychain profile created once
# with `xcrun notarytool store-credentials`, so the password or API key lives in the keychain
# and neither this script nor the process table ever sees it.
set -euo pipefail
cd "$(dirname "$0")"

: "${SWEEP_SIGN_ID:?Set SWEEP_SIGN_ID — see: security find-identity -v -p codesigning}"
: "${SWEEP_NOTARY_PROFILE:?Set SWEEP_NOTARY_PROFILE — see: xcrun notarytool store-credentials}"

APP="build/Sweep.app"

echo "==> Building and signing"
./make-app.sh release

# Notarization takes the app on its own first. The DMG is built afterwards from the *stapled*
# app, so the copy a user drags to Applications already carries its ticket and validates even
# if they are offline on first launch.
echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" build/Sweep-notarize.zip
xcrun notarytool submit build/Sweep-notarize.zip \
    --keychain-profile "$SWEEP_NOTARY_PROFILE" --wait
rm -f build/Sweep-notarize.zip
xcrun stapler staple "$APP"

echo "==> Packaging"
./make-dmg.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Sweep-$VERSION.dmg"

# The DMG is a separate artifact and needs its own ticket; stapling the app inside it does not
# cover the container the user actually downloads.
echo "==> Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$SWEEP_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# Verification is the point of the script. Everything above can appear to succeed while still
# producing something Gatekeeper rejects, so the release is only claimed after these pass.
echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

# The decisive check: assess the app the way macOS will after a download. Quarantine is applied
# to a throwaway copy so the build tree is left untouched.
Q="$(mktemp -d)"
cp -R "$APP" "$Q/"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$Q/Sweep.app"
spctl -a -vvv -t exec "$Q/Sweep.app"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
rm -rf "$Q"

echo
echo "Release ready: $DMG"
shasum -a 256 "$DMG"
