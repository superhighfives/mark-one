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
# Taken into a new folder, which replaces the last ones only if every
# screenshot worked. They all fail while the screen is locked.
new="$(mktemp -d)"
chmod 755 "$new"
trap 'rm -rf "$new"' EXIT
if ! "build/snap/Build/Products/Debug/Mark One.app/Contents/MacOS/Mark One" --snapshots "$new"; then
    echo "Some screenshots failed, so screenshots/app is unchanged. Is the screen locked?"
    exit 1
fi
rm -rf "$out"
mv "$new" "$out"
echo "Done. They're in screenshots/app."
