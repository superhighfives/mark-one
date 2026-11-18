#!/bin/bash
# Makes the screenshots on superhighfives.com/mark-one from the ones in
# screenshots/, as WebP in the website's public/assets, replacing the last
# ones. The setup bento comes from screenshots/app (scripts/snapshot-app.sh,
# no camera needed); the panel and the call are live shots in
# screenshots/raw (scripts/capture-screenshots.swift, with the camera).
# cwebp gives the same file from the same screenshot, so only pictures that
# changed show up in git.
#
#   scripts/website-screenshots.sh [path to superhighfives.com]
#
# Needs cwebp (brew install webp).

set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
site="${1:-$HOME/Development/superhighfives.com}"
assets="$site/public/assets"
[ -d "$assets" ] || { echo "No website at $site."; exit 1; }

size() { webpinfo "$1" 2>/dev/null | sed -n 's/^  Canvas size \([0-9]*\) x \([0-9]*\)$/\1x\2/p'; }

resized=()
# Website name, screenshot, WebP quality.
while read -r name shot quality; do
    file="$assets/markone-$name.webp"
    old="$( [ -f "$file" ] && size "$file" || true)"
    cwebp -quiet -q "$quality" "$root/screenshots/$shot.png" -o "$file"
    new="$(size "$file")"
    [ "$old" = "$new" ] || resized+=("markone-$name.webp: ${old:-new} to $new")
done <<'EOF'
panel           raw/01-panel                          85
facetime        raw/02-call                           85
bento-setup     app/welcome/10-connect-looking        90
bento-firmware  app/firmware/02-getting-the-firmware  90
bento-card      app/firmware/04-card-found            90
bento-install   app/firmware/06-install-from-the-card 90
bento-updating  app/panel/09-updating                 90
bento-ready     app/firmware/10-update-done           90
EOF

git -C "$site" status --short -- public/assets
if [ ${#resized[@]} -gt 0 ]; then
    echo "These changed size; change their width and height in src/app/(markone)/mark-one/markone-client.tsx to match:"
    printf '  %s\n' "${resized[@]}"
fi
