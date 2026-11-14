#!/bin/bash
# Screenshots each step of Mark One's Camera Firmware window into
# screenshots/firmware/, replacing the last ones. No camera or card is
# needed: a Debug build draws each step with made-up progress (see
# mac/MarkOne/App/Snapshots.swift). Each window flashes up while it's taken.
#
#   scripts/snapshot-firmware.sh
#
# The terminal app needs Screen Recording permission (System Settings >
# Privacy & Security).

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/screenshots/firmware"

cd "$root/mac/MarkOne"
xcodebuild -project MarkOne.xcodeproj -scheme MarkOne -configuration Debug \
    -derivedDataPath build/snap build -quiet
rm -f "$out"/*.png
"build/snap/Build/Products/Debug/Mark One.app/Contents/MacOS/Mark One" --snapshot-firmware "$out"
echo "Done. They're in screenshots/firmware."
