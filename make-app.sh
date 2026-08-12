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

# Ad-hoc signature: enough to run locally and to keep a stable bundle identity.
# Distribution needs a Developer ID certificate and notarization — see docs/DEPLOYMENT.md.
codesign --force --sign - --identifier com.sweep.app "$APP" >/dev/null 2>&1

echo "Built $APP"
