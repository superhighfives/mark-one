#!/bin/bash
# Builds Mark One for release: a Developer ID build, checked and notarized,
# ready for releasecast to put in a DMG. /release (.claude/commands/
# release.md) runs this, then releasecast, then publishes.
#
#   scripts/build-release.sh      prints the app's path when done
#
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in mac/MarkOne/project.yml
# first. Sparkle compares the build number, so it must go up every release.
# Leave the camera extension's own build number alone unless the extension
# changed (see "Camera extension updates" in NOTES.md).
#
# Needs, once:
#   - mac/MarkOne/Local.xcconfig with DEVELOPMENT_TEAM, and a Developer ID
#     Application certificate in the keychain
#   - notarytool credentials:
#       xcrun notarytool store-credentials mark-one --apple-id <id> --team-id <team>
#     (or set NOTARY_PROFILE to another profile's name)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT="$ROOT/mac/MarkOne"
OUT="$PROJECT/build/release"
NOTARY_PROFILE=${NOTARY_PROFILE:-mark-one}

step() { printf '\n==> %s\n' "$*"; }

cd "$PROJECT"
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
SYSTEM=$(sed -n 's/^ *macOS: *"\(.*\)"/\1/p' project.yml | head -1)

[ -n "$TEAM" ] || { echo "Set DEVELOPMENT_TEAM in Local.xcconfig" >&2; exit 1; }
if [ -n "$(git -C "$ROOT" status --porcelain -- mac/MarkOne)" ]; then
	echo "warning: mac/MarkOne has uncommitted changes" >&2
fi
echo "Mark One $VERSION ($BUILD), macOS $SYSTEM+, team $TEAM"

rm -rf "$OUT"
mkdir -p "$OUT"

step "Archiving"
xcodegen generate --quiet
xcodebuild -project MarkOne.xcodeproj -scheme MarkOne -configuration Release \
	-derivedDataPath build -archivePath "$OUT/MarkOne.xcarchive" \
	-allowProvisioningUpdates archive -quiet \
	MARK_ONE_FEED_URL=https://superhighfives.com/releases/mark-one/feed

step "Exporting with Developer ID"
cat >"$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/MarkOne.xcarchive" \
	-exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist" \
	-allowProvisioningUpdates -quiet
APP="$OUT/export/Mark One.app"
codesign --verify --deep --strict "$APP"
[ -d "$APP/Contents/Library/SystemExtensions" ] || { echo "The camera extension is missing" >&2; exit 1; }

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Mark One.zip"
xcrun notarytool submit "$OUT/Mark One.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/Mark One.zip"

step "Done"
echo "$APP"
