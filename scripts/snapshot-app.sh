#!/bin/bash
# Screenshots every window of Mark One, in each state, into
# screenshots/app/ (welcome, panel, settings, firmware), replacing the last
# ones. No camera or card is needed: a Debug build shows a made-up camera
# (see mac/MarkOne/App/Snapshots.swift), and installs and looks for nothing.
# Each window flashes up while it's taken; leave the mouse alone until it's
# done.
#
#   scripts/snapshot-app.sh
#
# The terminal app needs Screen Recording permission (System Settings >
# Privacy & Security).

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/screenshots/app"

cd "$root/mac/MarkOne"
xcodebuild -project MarkOne.xcodeproj -scheme MarkOne -configuration Debug \
    -derivedDataPath build/snap build -quiet 2>&1 | grep -v "multiple matching destinations\|platform:macOS" || true
rm -rf "$out"
"build/snap/Build/Products/Debug/Mark One.app/Contents/MacOS/Mark One" --snapshots "$out"
echo "Done. They're in screenshots/app."
