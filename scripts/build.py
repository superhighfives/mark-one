"""Patch the E-M5 v2.3 firmware and repack it.

Usage:
  uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN patched/E0972300.BIN [patch ...]
  uv run scripts/build.py --roundtrip fw/OLY_E_097_2300_0000_0000.BIN

Patches are defined in PATCHES below as (runtime address, expected bytes, new bytes),
applied to the decoded main block. Each expected value is checked first, so a
patch can't land on the wrong build.
"""
import hashlib, struct, sys, os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
import olyfw  # noqa: E402

BASE = 0x7E421020          # runtime address of main block byte 0
STOCK_SHA256 = 'cb158dbdd8092856e8060354b008369f7d33dff32a1204e966ef0d5bce85e535'
MAIN_SHA256 = '4edb88f3b552ef2fb9066ce7d1ca8bf5b44494f4c21865ac02dcac39e833fcf9'

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
}


def split(fw):
    blocks, end = olyfw.walk(fw)
    assert end == len(fw), 'unexpected trailing data'
    for off, hd, body in blocks:
        assert hd['cksum_ok'], f'bad checksum in block at {off:#x}'
    return blocks


def pack_block(fw, off, hd, body):
    """Rebuild one block (head + scrambled body + tail) from a decoded body."""
    head = bytearray(fw[off:off + 32])
    tail = bytearray(fw[off + 32 + hd['len']:off + 64 + hd['len']])
    assert len(body) == hd['len']
    struct.pack_into('<I', tail, 0x1C, 0)
    total = (olyfw.sum32(head) + olyfw.sum32(body) + olyfw.sum32(tail)) & 0xFFFFFFFF
    struct.pack_into('<I', tail, 0x1C, (-total) & 0xFFFFFFFF)
    enc = olyfw.scramble(body) if hd['scrambled'] else body
    return bytes(head) + enc + bytes(tail)


def build(fw, names):
    blocks = split(fw)
    out = bytearray(fw)
    off, hd, main = blocks[0]
    assert hashlib.sha256(main).hexdigest() == MAIN_SHA256, 'main block is not stock v2.3'
    main = bytearray(main)
    for name in names:
        for addr, old, new in PATCHES[name]:
            o = addr - BASE
            old_b, new_b = bytes.fromhex(old), bytes.fromhex(new)
            got = bytes(main[o:o + len(old_b)])
            assert got == old_b, f'{name} @ {addr:#x}: expected {old}, found {got.hex()}'
            main[o:o + len(new_b)] = new_b
            print(f'  {name}: {addr:#010x} {old} -> {new}')
    packed = pack_block(fw, off, hd, bytes(main))
    out[off:off + len(packed)] = packed
    return bytes(out), bytes(main)


def main():
    if sys.argv[1] == '--roundtrip':
        fw = open(sys.argv[2], 'rb').read()
        out, _ = build(fw, [])
        print('roundtrip identical:', out == fw)
        sys.exit(0 if out == fw else 1)
    src, dst, names = sys.argv[1], sys.argv[2], sys.argv[3:]
    fw = open(src, 'rb').read()
    assert hashlib.sha256(fw).hexdigest() == STOCK_SHA256, 'input is not stock v2.3'
    out, main_patched = build(fw, names)
    # Re-read the result to confirm every block still checksums and the
    # patched main block decodes to exactly what was intended.
    blocks = split(out)
    assert blocks[0][2] == main_patched
    for (o1, h1, b1), (o2, h2, b2) in zip(split(fw)[1:], blocks[1:]):
        assert b1 == b2, f'non-main block at {o1:#x} changed'
    diff = sum(1 for a, b in zip(fw, out) if a != b)
    os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
    open(dst, 'wb').write(out)
    print(f'wrote {dst}: {len(out)} bytes, {diff} file bytes differ, sha256 {hashlib.sha256(out).hexdigest()}')


if __name__ == '__main__':
    main()
