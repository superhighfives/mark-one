#!/bin/bash
# Builds a Mark One release: a notarized Developer ID build in a signed,
# notarized DMG, signed for Sparkle. Prints the front matter for its entry
# in superhighfives.com's changelog/mark-one/<version>.md.
#
#   scripts/release.sh            build, notarize and sign
#   scripts/release.sh --upload   then upload the DMG to R2
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
#   - Sparkle's private key in the keychain, under the account "mark-one"
#     (made by Sparkle's generate_keys --account mark-one; back it up with
#     generate_keys --account mark-one -x <file>, and keep the file safe)
#   - for --upload: wrangler logged in to the account with the
#     mark-one-releases bucket

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROJECT="$ROOT/mac/MarkOne"
OUT="$PROJECT/build/release"
NOTARY_PROFILE=${NOTARY_PROFILE:-mark-one}
BUCKET=mark-one-releases
UPLOAD=0
[ "${1:-}" = "--upload" ] && UPLOAD=1

step() { printf '\n==> %s\n' "$*"; }

cd "$PROJECT"
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig)
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
SYSTEM=$(sed -n 's/^ *macOS: *"\(.*\)"/\1/p' project.yml | head -1)
DMG="$OUT/Mark-One-$VERSION.dmg"
SPARKLE_BIN="$PROJECT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

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

step "Making the DMG"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Mark One.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Mark One" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO "$DMG"
rm -rf "$OUT/dmg"
IDENTITY=$(security find-identity -v -p codesigning |
	sed -n "s/.*\"\(Developer ID Application: .*($TEAM)\)\"/\1/p" | head -1)
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate for $TEAM" >&2; exit 1; }
codesign --sign "$IDENTITY" --timestamp "$DMG"

step "Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

step "Signing for Sparkle"
# Prints: sparkle:edSignature="…" length="…"
SPARKLE=$("$SPARKLE_BIN/sign_update" --account mark-one "$DMG")
SIGNATURE=$(echo "$SPARKLE" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
SIZE=$(echo "$SPARKLE" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

if [ "$UPLOAD" = 1 ]; then
	step "Uploading to R2"
	npx --yes wrangler r2 object put "$BUCKET/$(basename "$DMG")" --file "$DMG" \
		--content-type application/x-apple-diskimage --remote
fi

step "Done: $DMG"
cat <<EOF

Add this as changelog/mark-one/$VERSION.md on superhighfives.com, with a
title and notes:

---
title: TODO
date: $(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')
signature: $SIGNATURE
size: $SIZE
build: $BUILD
system: $SYSTEM
---
EOF
[ "$UPLOAD" = 1 ] || echo "
Then upload the DMG:
  npx wrangler r2 object put $BUCKET/$(basename "$DMG") --file \"$DMG\" --remote"
