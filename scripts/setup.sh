#!/bin/sh
# Download the stock E-M5 v2.3 firmware and the container unpacker, check
# their hashes, and unpack the firmware into unpacked/.
set -eu
cd "$(dirname "$0")/.."

FW=fw/OLY_E_097_2300_0000_0000.BIN
FW_SHA=cb158dbdd8092856e8060354b008369f7d33dff32a1204e966ef0d5bce85e535
# Olympus's own server (dl01.om-digitalsolutions.net) refuses direct
# downloads, so this uses the community mirror. The hash pins the exact file.
FW_URL=http://xdel.ru/downloads/olympus-firmware/original/em5/OLY_E_097_2300_0000_0000.BIN.lzma

OLYFW=tools/olyfw.py
OLYFW_SHA=496500ed898a3aa1def3a183cf8d4ab26ee9e5ad9e39fc734ca8238925469e10
OLYFW_URL=https://raw.githubusercontent.com/xulfr/om-emu/21b04a5cea6dd725117c5b1d4611a98891648b10/tools/olyfw.py

check() {
  echo "$2  $1" | shasum -a 256 -c - >/dev/null || {
    echo "hash mismatch for $1" >&2
    exit 1
  }
}

mkdir -p fw tools unpacked

if [ ! -f "$FW" ]; then
  curl -sSfL -o "$FW.lzma" "$FW_URL"
  xz --format=lzma -d "$FW.lzma"
fi
check "$FW" "$FW_SHA"

if [ ! -f "$OLYFW" ]; then
  curl -sSfL -o "$OLYFW" "$OLYFW_URL"
fi
check "$OLYFW" "$OLYFW_SHA"

(cd unpacked && python3 -I ../tools/olyfw.py "../$FW" --dump >/dev/null)
ln -sf OLY_E_097_2300_0000_0000.BIN.blk00000000.OE.0100.bin unpacked/main.bin
check unpacked/main.bin 4edb88f3b552ef2fb9066ce7d1ca8bf5b44494f4c21865ac02dcac39e833fcf9

echo "Firmware unpacked into unpacked/. Main code block: unpacked/main.bin"
