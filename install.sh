#!/bin/bash
# Builds Sweep with the Developer ID identity and replaces /Applications/Sweep.app.
#
# There must only ever be ONE Sweep.app on the machine. TCC keys a Full Disk Access grant to
# the bundle id plus the code signature, so a second, ad-hoc-signed copy under build/ has the
# same id but a different (and per-build changing) signature: the grant made in System Settings
# lands on whichever copy LaunchServices prefers — the /Applications one — and never on the
# build. Install over /Applications and the problem cannot occur.
set -euo pipefail
cd "$(dirname "$0")"
: "${SWEEP_SIGN_ID:=Developer ID Application: Udhayveer Singh (P66SB4MX92)}"
export SWEEP_SIGN_ID
./make-app.sh "${1:-release}"
osascript -e 'tell application "Sweep" to quit' >/dev/null 2>&1 || true
pkill -x Sweep 2>/dev/null || true
sleep 1
rm -rf /Applications/Sweep.app
ditto build/Sweep.app /Applications/Sweep.app
echo "Installed /Applications/Sweep.app"
