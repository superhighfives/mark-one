"""Patch the E-M5 v2.3 firmware and repack it.

Usage:
  uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN patched/E0972300.BIN [patch ...] [version=X.Y]
  uv run scripts/build.py --roundtrip fw/OLY_E_097_2300_0000_0000.BIN

Patches are defined in PATCHES below as (runtime address, expected bytes, new bytes),
applied to the decoded main block. Addresses below BASE land in the main
block's 32-byte head, which the camera copies to RAM just before the code.
Each expected value is checked first, so a patch can't land on the wrong
build. Expected values longer than 8 bytes are given as stock(length,
sha256), so this file doesn't copy Olympus's code. STRINGS replaces menu strings in every language of the resource
block (0101).
"""
import hashlib, struct, sys, os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
import olyfw  # noqa: E402

BASE = 0x7E421020          # runtime address of main block byte 0
WEBCAM_REVISION = 4        # the webcam patches' revision; see the marker at 0x7eab0414
STOCK_SHA256 = 'cb158dbdd8092856e8060354b008369f7d33dff32a1204e966ef0d5bce85e535'
MAIN_SHA256 = '4edb88f3b552ef2fb9066ce7d1ca8bf5b44494f4c21865ac02dcac39e833fcf9'


def stock(length, sha256):
    """Olympus's code a patch replaces, known by its length and hash."""
    return (length, sha256)


def matches(old, got):
    if isinstance(old, tuple):
        return len(got) == old[0] and hashlib.sha256(got).hexdigest() == old[1]
    return got == bytes.fromhex(old)


PATCHES = {
    # Shooting mode treats HDMI like analog video: pick it as the display
    # target and hand it to the GUI as output type 4 (doHdmiConnectChange,
    # which calls CameraCommon::changeOutLine(0x08)), instead of jumping to
    # HDMI playback.
    'hdmi-liveview': [
        # display target selector: getCompositeState (+44) -> getHdmiState (+48)
        (0x7EDC98D5, '2c', '30'),
        # apply routine, VIDEO target: GUI output type 3 (video) -> 4 (HDMI)
        (0x7EDC9A9F, '03', '04'),
        # ShootingCommon event 0x01050004 (HDMI connected):
        # request PLAYHDMI (0x7edce387) -> receiveConnectChange (0x7edc95eb)
        (0x7EF00268, '87e3dc7e', 'eb95dc7e'),
        # ShootingCommon event 0x01050005 (HDMI disconnected): same handler
        (0x7EF00278, '9de3dc7e', 'eb95dc7e'),
    ],
    # PTP commands for exploring over USB, in MTP mode (asm/usb.s):
    # 0x9484 peek (read memory), 0x9485 poke (write memory), 0x9486 run
    # (call a function). They take over the 0x9805, 0x9801 and 0x9802
    # slots, which only Windows MTP browsing uses.
    'usb-tools': [
        # register 0x9484 instead of 0x9805 (GetObjectPropList)...
        (0x7F0D4BBC, '05980000', '84940000'),
        # ...with the peek handler instead of 0x7f0d6434
        (0x7F0D4BC6, '34640d7f', 'e3aaaa7e'),
        # register 0x9485 instead of 0x9801 (GetObjectPropsSupported),
        # receiving data (direction 2) instead of sending it (1), with the
        # poke handler instead of 0x7f0d6221
        (0x7F0D4B7D, '01980000', '85940000'),
        (0x7F0D4B82, '01', '02'),
        (0x7F0D4B87, '21620d7f', '1cabaa7e'),
        # register 0x9486 instead of 0x9802 (GetObjectPropDesc), with no
        # data (direction 0), with the run handler instead of 0x7f0d62b4
        (0x7F0D4B92, '02980000', '86940000'),
        (0x7F0D4B97, '01', '00'),
        (0x7F0D4B9C, 'b4620d7f', '46abaa7e'),
        # advertise them instead of 0x9801, 0x9802 and 0x9805
        (0x7F128970, '01980298', '85948694'),
        (0x7F128976, '0598', '8494'),
        # the handlers, over the `sdk api changeOutLine` debug command,
        # which only the serial console reaches
        (0x7EAAAAE3,
         stock(145, '2eb0856da4bc3497673849f88246f717ccc4e38f4daeab82133da2e5abe26898'),
         'cff0f8feec470cf80810f80c14271d20fccc01000040f208c914af00c810f1e8'
         '8c8ddd32f16200f0182701205c0cf1dcf07000f8100cdff024cff0f8feec470c'
         'f80810270220ddd1f16200a010a000c8ddf1e8dd3af26200e014a001c9d02701'
         '20cacbcff0f8feec470c92f82e10f80214f80618f82620f8221cf0f35d0c2e01'
         '20f0798a02f8190cf81110f83114dff024'),
    ],
    # A "Webcam" connection: a fifth choice in the USB prompt (Storage,
    # MTP, Webcam, Print, Exit) and in Custom menu > USB Mode. It connects
    # like MTP but as connection type 7 (0x605f0d14), which the computer can
    # read to tell it apart. Type 7 uses PC sub-state 0x6004, which already
    # takes the "start camera control" events. Also bakes in what Mark One
    # otherwise loads at run time. See NOTES.md.
    'webcam': [
        # USB prompt: list five items (asm/webcam/prompt.s)
        (0x7EEC6DFB,
         stock(95, '593249da7f773be092180d2d3bd90dc7a2dd65295013e20c688b715fad6624bf'),
         '88dd6604000000002ce305f8933c00f8923ef8923f8505f89742f89344f89746fc'
         '87b0ce2b60950ef16dfcdc506eec7e8002f05104f855018502f85507f064f87508'
         '200221288001fcd85a6eec7ec9e4dcfe0000000a01df05fd03d1004303'),
        # USB prompt OK: Webcam sends GUI param 20 (asm/webcam/ok.s)
        (0x7EEC7101,
         stock(26, '99ee9403b4ae3093e6933c7fec8c9afd2331b8cae87d4d406f975271508a9994'),
         '1ca004c822fcdc1771ec7ef160f0448011dc570000000f101411'),
        # checkEndUsbSelect: param 20 -> connection type 7 (asm/webcam/select.s)
        (0x7EDD5BB2,
         stock(31, '70d1696173a6b5ed5d1b8457973a380f69e8a3efebd477e4ffb944ab56133aa4'),
         'f8020428f1a005c7048003fcdcc95bdd7ef160f040ca0a010204050507cbcb'),
        # USB Mode setting 7 -> connection type 7 (asm/webcam/mode.s)
        (0x7EDD54FF,
         stock(42, '902b9549055086e7c6eb0bfb1d11ea637406e700161c61da2304ffbf95aac8a1'),
         '04fac8ff00c8128501a007c50cfcdc2155dd7ef160f044fc85140d5f60dc190000'
         '000101040302020107'),
        # startPc: mass storage only for type 1, MTP for 2 and 7
        # (cmp 2,d0; beq -> cmp 1,d0; bne)
        (0x7EDD5569, 'a002c804', 'a001c904'),
        # Custom menu USB Mode: five options. The stock records at 0x7f00ab30
        # run straight into the next list's, so copy them, with Webcam
        # (string 0x3fd, value 7) after MTP, over console-only code...
        (0x7EAAF680,
         stock(140, 'de04e82fd578999ede3c876a4cf7811459936d1ede833cb077c7439096695c7f'),
         '000247000000000000000000d0070000ff000000c0000000c500000000020a0100'
         '00000000000000d007000000000000c0000000c50000000002df05000000000000'
         '0000d007000004000000c0000000c50000000002fd030000000000000000d00700'
         '0007000000c0000000c50000000002d1000000000000000000d007000002000000'
         'c0000000c5000000'),
        # ...and point the list header at them, with a count of 5
        (0x7F00C63C, stock(16, 'b4bba7be7f16d0314b0b3dffd09ea85f0a14a263b6397d5aa74a504ee7c071a8'), '76000500000000000100000080f6aa7e'),
        # Mark One's run-time helpers, over console-only code: read32 and
        # write32 (see ptp.py), the key stub (asm/key.s) and the button stub
        # (asm/button.s)
        (0x7EAAAB74, stock(12, '20c6e360bb9ef99a61f316395c28f451cf2fb048383895c47823ff75553d9b14'), '70f0fccbcbcb6070f0fccbcb'),
        (0x7EAB0380, stock(14, '51f403fdc60baed81304472a34eb4344344ba61f62cd46d41c2db607ba1778a0'), 'f8fef8dd9818caff0020df0008cb'),
        (0x7EAAF5E0, stock(14, '8d1b005026535cf08274d4c9980f687f9d1309a8cc7cdd968c2ca40c9888aeed'), 'f8fef8ddba00f3ffc00cdf0008cb'),
        # power switch in PC shooting (see NOTES.md, "Power switch in webcam
        # mode"): 0x7edc725f -> 0x7edc726a
        (0x7EEEA8B0, '5f72dc7e', '6a72dc7e'),
        # firmware update commands over MTP (asm/firmup.s): the end of MTP's
        # command setup jumps to a stub, over console-only code, that also
        # registers modes 0 and 5's update commands
        (0x7F0D4BCA, 'cded4ef014df0004', 'dc36b89dffcbcbcb'),
        (0x7EAB0400, stock(17, '1be35d96dbc30e5f0071bf172e0a98d7c65044271db260d8f5352865567385e6'), 'ddb7966200f014dd9d4562002008df0004'),
        # Webcam-mode movies that don't touch the card (asm/nocard.s): no card
        # needed, no empty movie file, and no time limit, only while the
        # connection type is 7. The stubs go over the console-only `sdk api`
        # EV_* dump; each hook is a jump to its stub, padded with nops.
        (0x7EAAF760,
         stock(780, '3ecfe38ecadb3c5fb429d2bcc7c7f04c4a92419d7321603a3965750efb1cceff'),
         '00000000dd36c1d0ff0004fca5140d5f60a507c911fccde2ff0e00f81420f814'
         '24f81428dc3ecad0ffcf80fca6140d5f60aa07ce80c907dc7bd2d0ffdddac8d0'
         'ffb010dc6fd2d0ffcf80fca6140d5f60aa07ce80c908fccc00dd6d00fc81d4fc'
         '7260dca384cfffcf80fca6140d5f60aa07ce80c90800dc580cd1ffdd740cd1ff'
         'e010dc4c0cd1ffcf80fca6140d5f60aa07ce80c91c00fc81d8525b60fc8160f7'
         'aa7eddd76acfff000000dc0779cfffdd317acffff020dcfb78cfffcf80fca614'
         '0d5f60aa07ce80c932f8240c71f86504a501c9068100f104f86506a501c909fc'
         'a560f7aa7ee4fc8160f7aa7edd8d6acfff000000dc2d79cfffddf97dcffff01c'
         'dc2179cfffcf80fca6140d5f60aa07ce80c919f8240cfca460f7aa7e61dd5c6a'
         'cfff000000dc1779cfffdd877fcfffa010dc0b79cfffcf80fca6140d5f60aa07'
         'ce80c91ef8240cf821080060f82114800260dd276acfff00008002dc8e78cfff'
         'dd697ecffff020dc8278cfffcf80fca6140d5f60aa07ce80c933fccc18f9aa7e'
         'f81018fccc00002140f81010f81014fcdcccf9aa7efcdddc525b608508706150'
         '5129ffc9fa00dc7c80cfffdde0c8cfff0004dc7080cfff000000000000000000'
         '9cf9aa7e50313031303030314d4f560000000000000000000000000000006100'
         '0000000000000000000000000000214000002140000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000064000100'
         '2020202000000000000000000000000000000000000000000000000000000000'
         '000000003130304f4c594d502020200000006400000060001c1e020000000000'
         '0000000000000000042b0000433a5c4443494d5c3130304f4c594d505c503130'
         '31303030312e4d4f56000000cf80fca6140d5f60aa07ce80c907dce3c9d0ffdd'
         '320bd1ff300cdcd7c9d0ffcf80fca6140d5f60aa07ce80c907dcbdc9d0ffddb5'
         '0bd1ff0004dcb1c9d0ffcf80fca6140d5f60aa07ce80c90800dcbe05d1ffddc0'
         '77cfffc00cdcb205d1ffdd8702fdffc008cf80fca6140d5f60aa07ce80c908fc'
         'cc00f00000dc851e0c000000'),
        (0x7E7BC1BD, 'cdddf60004', 'dca7352f00'),  # S1: aud_wait limits
        (0x7E7BCA0D, 'cd69f6b010', 'dc7c2d2f00'),  # S2: TIME_LIMIT check
        (0x7E7A7C5F, 'fc81d4fc7260', 'dc497b3000cb'),  # S3: muxer maximum time
        (0x7E7C0429, 'cd2600e010', 'dc9ef32e00'),  # S4: MOV_FILE write
        (0x7E7A710C, 'cd3401f020', 'dcdb863000'),  # S5: QT_FILE open
        (0x7E7A717C, 'cdd604f01c', 'dc9f863000'),  # S6: QT_FILE seek
        (0x7E7A7197, 'cd7a06a010', 'dcce863000'),  # S7: QT_FILE position
        (0x7E7A7144, 'cde505f020', 'dc52873000'),  # S8: QT_FILE read
        (0x7E7A797D, 'cd6e480004', 'dc4f7f3000'),  # S9: IMDF 50 (file number)
        (0x7E7BC3D8, 'cd5941300c', 'dc14362f00'),  # S10: record_end
        (0x7E7BC3D1, 'cd02420004', 'dc3a362f00'),  # S11: record cancel
        (0x7E7BFFF0, 'dd0e72feffc00c', 'dc3afa2e00cbcb'),  # S12: QT_FILE remove
        (0x7EB718E3, 'ddeee3f0ffc008', 'dc67e1f3ffcbcb'),  # S13: movie start media check
        # A list of finished video frames, so Mark One copies each frame
        # exactly (asm/frames.s): the stub and its empty list, over the
        # console-only `sdk api` commands from getDisplayDeviceState, and the
        # hook in the Video Encode plug-in's handler, where each frame's size
        # becomes known.
        (0x7EAAAB8E,
         stock(1154, 'b018e778d8bfa8542bb04a436a5d8ef69266a51d01de9edcf331ee70e79612b1'),
         'f81060f814648001f81068fca4140d5f60a007c936fca400acaabef1e1f8e03f'
         'f8c004fcde10acaabef162f80058f80460e462f80064f81204f80018f81208f8'
         '360c45fc8400acaabe00dce85ba8ff0000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000000000000000000000000000000000000000000000000000000000000000'
         '0000'),
        (0x7E5307B9, 'dd3170ffff0000', 'dcd5a35700cbcb'),  # jmp frames; nop; nop
        # Unplugging mid-call leaves the camera usable (asm/unplug.s): the
        # stub, over console usage code after the button stub, and the
        # system event callback's first two instructions replaced by a jump
        # to it. Mark One loaded both at run time before revision 4.
        (0x7EAAF600,
         stock(94, '9d01ce1c29fdcc4edf28e8ccee3ae9f4e79e0265da8b0bc1c510222108c4bcda'),
         'a509c952f8fef0430047044208460cfca4bced5a60fce00000fffffc81bced5a60'
         'fcfff9bb0100fca4f41f2b60a010c91afccc09120002fcff490d0000fccc091201'
         '02fcff3d0d00005c005d045808590cf8fe10cff0f8fee4dcb89a3200'),
        (0x7EDD910C, 'cff0f8fee4', 'dcf464cdff'),  # jmp unplug
        # "MARK" and the firmware revision (a little-endian u32), which Mark
        # One reads to tell whether the camera needs an update. Bump it with
        # every change to these patches.
        (0x7EAB0414, '7e8004ddc15fffff', '4d41524b' + struct.pack('<I', WEBCAM_REVISION).hex()),
    ],
}


def version_patch(name):
    """`version=X.Y`: the version the camera reports, one digit each side.

    The main block head's version word sets the displayed version (setting
    0xc082) at boot, and the body version that GetVersions (0x9120) reports
    has the stock 0x2300 hardcoded at 0x7f0dd970 (`mov 0x2300,d2`).
    """
    major, minor = name.split('=')[1].split('.')
    assert major.isdigit() and minor.isdigit() and len(major) == len(minor) == 1, name
    version = f'{major}{minor}'
    # The card updater refuses an older version than the one installed, so
    # a camera running anything above stock 2.3 couldn't go back to stock.
    if version > '23':
        sys.exit(f'{name}: versions above 2.3 would block a return to stock firmware')
    return [(0x7E421010, '0023', f'00{version}'), (0x7F0DD970, '2e0023', f'2e00{version}')]

# Menu string replacements for the resource block, as {string ID: text}.
# Each language has a table of 1695 pointers (base 0xbff3d020) to UTF-16
# strings; a replacement must be no longer than the original.
STRINGS = {
    # "A. OLYMPUS PENPAL Share", only shown for the PENPAL accessory
    'webcam': {0x3FD: 'Webcam'},
}
STRING_COUNT, STRING_BASE = 1695, 0xBFF3D020


def string_tables(body):
    """Find each language's string pointer table in the resource block.

    The block starts with a directory of {load address, size} entries; the
    languages are the entries holding a table whose first pointer is 8 bytes
    before STRING_BASE and whose pointers all fall inside the entry.
    """
    tables = []
    for k in range(64):
        load, size = struct.unpack_from('<II', body, 16 * k)
        if load == 0:
            break
        start = load - 0x92E40000
        first = struct.pack('<I', STRING_BASE - 0x18)
        at = body.find(first, start, start + size)
        while at != -1:
            if at + 4 * STRING_COUNT <= start + size:
                ptrs = struct.unpack_from(f'<{STRING_COUNT}I', body, at)
                if all(STRING_BASE - 0x20 <= p < STRING_BASE + size for p in ptrs):
                    tables.append((start, ptrs))
                    break
            at = body.find(first, at + 4, start + size)
    return tables


def patch_strings(body, replacements):
    body = bytearray(body)
    tables = string_tables(body)
    assert len(tables) == 34, f'expected 34 languages, found {len(tables)}'
    for start, ptrs in tables:
        for string, text in replacements.items():
            at = start + ptrs[string] - STRING_BASE
            end = at
            while body[end:end + 2] != b'\0\0':
                end += 2
            new = text.encode('utf-16-le')
            assert len(new) <= end - at, f'{text!r} is longer than string {string:#x} at {at:#x}'
            body[at:end] = new + bytes(end - at - len(new))
    return bytes(body)


def split(fw):
    blocks, end = olyfw.walk(fw)
    assert end == len(fw), 'unexpected trailing data'
    for off, hd, body in blocks:
        assert hd['cksum_ok'], f'bad checksum in block at {off:#x}'
    return blocks


def pack_block(fw, off, hd, body, head=None):
    """Rebuild one block (head + scrambled body + tail) from a decoded body."""
    head = bytearray(head if head is not None else fw[off:off + 32])
    tail = bytearray(fw[off + 32 + hd['len']:off + 64 + hd['len']])
    assert len(body) == hd['len']
    struct.pack_into('<I', tail, 0x1C, 0)
    total = (olyfw.sum32(head) + olyfw.sum32(body) + olyfw.sum32(tail)) & 0xFFFFFFFF
    struct.pack_into('<I', tail, 0x1C, (-total) & 0xFFFFFFFF)
    enc = olyfw.scramble(body) if hd['scrambled'] else body
    return bytes(head) + enc + bytes(tail)


def build(fw, names):
    """Returns the patched file and the decoded bodies it should contain."""
    blocks = split(fw)
    out = bytearray(fw)
    off, hd, main = blocks[0]
    assert hashlib.sha256(main).hexdigest() == MAIN_SHA256, 'main block is not stock v2.3'
    head, main = bytearray(fw[off:off + 32]), bytearray(main)
    for name in names:
        for addr, old, new in (version_patch(name) if name.startswith('version=') else PATCHES[name]):
            target, o = (head, addr - BASE + 32) if addr < BASE else (main, addr - BASE)
            new_b = bytes.fromhex(new)
            got = bytes(target[o:o + (old[0] if isinstance(old, tuple) else len(old) // 2)])
            assert matches(old, got), f'{name} @ {addr:#x}: not the expected stock code'
            target[o:o + len(new_b)] = new_b
            print(f'  {name}: {addr:#010x} {got.hex()[:24]} -> {new[:24]}')
    packed = pack_block(fw, off, hd, bytes(main), head)
    out[off:off + len(packed)] = packed
    bodies = {off: bytes(main)}
    replacements = {k: v for name in names for k, v in STRINGS.get(name, {}).items()}
    if replacements:
        roff, rhd, resources = next(b for b in blocks if b[1]['flags'] == 0x101)
        resources = patch_strings(resources, replacements)
        packed = pack_block(fw, roff, rhd, resources)
        out[roff:roff + len(packed)] = packed
        bodies[roff] = resources
        print(f'  strings: {", ".join(f"{k:#x} -> {v!r}" for k, v in replacements.items())} in 34 languages')
    return bytes(out), bodies


def main():
    if sys.argv[1] == '--roundtrip':
        fw = open(sys.argv[2], 'rb').read()
        out, _ = build(fw, [])
        print('roundtrip identical:', out == fw)
        sys.exit(0 if out == fw else 1)
    edits_path = None
    if '--edits' in sys.argv:
        i = sys.argv.index('--edits')
        edits_path = sys.argv[i + 1]
        del sys.argv[i:i + 2]
    src, dst, names = sys.argv[1], sys.argv[2], sys.argv[3:]
    fw = open(src, 'rb').read()
    assert hashlib.sha256(fw).hexdigest() == STOCK_SHA256, 'input is not stock v2.3'
    out, bodies = build(fw, names)
    # Re-read the result to confirm every block still checksums and decodes
    # to exactly what was intended, and that no other block changed.
    for (o1, h1, b1), (o2, h2, b2) in zip(split(fw), split(out)):
        assert o1 == o2 and b2 == bodies.get(o1, b1), f'block at {o1:#x} is not what was intended'
    diff = sum(1 for a, b in zip(fw, out) if a != b)
    os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
    open(dst, 'wb').write(out)
    print(f'wrote {dst}: {len(out)} bytes, {diff} file bytes differ, sha256 {hashlib.sha256(out).hexdigest()}')
    if edits_path:
        write_edits(edits_path, fw, out)


def write_edits(path, fw, out):
    """Write the changes as byte edits on the stock file, for Mark One.

    Mark One downloads stock firmware from Olympus and applies these, so it
    never ships Olympus code. Edits closer than 8 bytes are merged.
    """
    import json
    edits, i = [], 0
    while i < len(fw):
        if fw[i] == out[i]:
            i += 1
            continue
        j = i
        while j < len(fw) and any(fw[k] != out[k] for k in range(j, min(j + 8, len(fw)))):
            j += 1
        edits.append([i, out[i:j].hex()])
        i = j
    json.dump({'stock_sha256': STOCK_SHA256, 'sha256': hashlib.sha256(out).hexdigest(),
               'size': len(out), 'revision': WEBCAM_REVISION, 'edits': edits}, open(path, 'w'), indent=0)
    print(f'wrote {path}: {len(edits)} edits')


if __name__ == '__main__':
    main()
