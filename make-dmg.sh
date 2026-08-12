#!/bin/bash
# Packages build/Sweep.app into a drag-to-Applications disk image.
#
# hdiutil straight from a staging folder, no background art or custom .DS_Store: those need a
# scripted Finder window, which fails on any machine without Automation permission granted to
# the shell. A two-icon window is self-explanatory without it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Sweep.app"
[ -d "$APP" ] || { echo "No $APP — run ./make-app.sh release first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Sweep-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Sweep" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built $DMG"
shasum -a 256 "$DMG"
