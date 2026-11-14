#!/bin/sh
# Install the Python dependencies, download the stock E-M5 v2.3 firmware and
# the container unpacker, check their hashes, and unpack the firmware into
# unpacked/.
set -eu
cd "$(dirname "$0")/.."

FW=fw/OLY_E_097_2300_0000_0000.BIN
FW_SHA=cb158dbdd8092856e8060354b008369f7d33dff32a1204e966ef0d5bce85e535
# Olympus's update server hands out a signed link to the latest E-M5
# firmware, 2.3, when asked the way OM Workspace asks (see "Doing it
# from Mark One" in NOTES.md). The app asks the same way (FirmwareImage.swift).
FW_SERVER=https://fw01.om-digitalsolutions.net/ww_inform/fcache.do

OLYFW=tools/olyfw.py
OLYFW_SHA=496500ed898a3aa1def3a183cf8d4ab26ee9e5ad9e39fc734ca8238925469e10
OLYFW_URL=https://raw.githubusercontent.com/xulfr/om-emu/21b04a5cea6dd725117c5b1d4611a98891648b10/tools/olyfw.py

check() {
  echo "$2  $1" | shasum -a 256 -c - >/dev/null || {
    echo "hash mismatch for $1" >&2
    exit 1
  }
}

uv sync --quiet

mkdir -p fw tools unpacked

if [ ! -f "$FW" ]; then
  url=$(curl -sSf -A Olympus -H "Content-Type: text/xml; Charset=UTF-8" --data-binary @- "$FW_SERVER" <<EOF2 |
<?xml version="1.0"?>
<firmware_demand>
<revision>0001</revision>
<mac_address>00-00-00-00-00-00</mac_address>
<time>$(date +%Y%m%d%H%M%S)</time>
<language>ENU</language>
<application>FWUT</application>
<type>0000</type>
<version>00005000</version>
<os>WIN</os>
<country_code>0001</country_code>
<hardwares>
<firmup_mode>0</firmup_mode>
<hardware_info>
<hard_code>OLYE097000000000</hard_code>
<firmware_version>00001000</firmware_version>
<serial_no>000000000</serial_no>
<default_languages><code>ENU</code></default_languages>
</hardware_info>
</hardwares>
</firmware_demand>
EOF2
    sed -n 's|.*<url>\(.*\)</url>.*|\1|p' | sed 's/&amp;/\&/g')
  [ -n "$url" ] || { echo "Olympus's update server didn't offer the firmware" >&2; exit 1; }
  curl -sSfL -o "$FW" "$url"
fi
check "$FW" "$FW_SHA"

if [ ! -f "$OLYFW" ]; then
  curl -sSfL -o "$OLYFW" "$OLYFW_URL"
fi
check "$OLYFW" "$OLYFW_SHA"

(cd unpacked && uv run ../tools/olyfw.py "../$FW" --dump >/dev/null)
ln -sf OLY_E_097_2300_0000_0000.BIN.blk00000000.OE.0100.bin unpacked/main.bin
check unpacked/main.bin 4edb88f3b552ef2fb9066ce7d1ca8bf5b44494f4c21865ac02dcac39e833fcf9

echo "Firmware unpacked into unpacked/. Main code block: unpacked/main.bin"
