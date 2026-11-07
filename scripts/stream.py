"""Stream the camera's H.264 video over USB while it records a movie.

Needs the usb-tools firmware, the camera in shooting mode with USB
connected (`uv run scripts/ptp.py shoot`), and a movie recording. Writes a
raw H.264 stream (Annex B) to stdout or a file:

  uv run scripts/stream.py --raw | mac/viewer/viewer       # lowest delay
  uv run scripts/stream.py | ffplay -fflags nobuffer -flags low_delay -f h264 -
  uv run scripts/stream.py -o clip.h264 --seconds 10

With --raw it decodes each frame as it arrives (PyAV) and writes raw
1920x1080 NV12 frames, full range. The ffmpeg command line holds back
about 20 frames (two thirds of a second) before showing anything; decoding
one frame at a time shows each frame as soon as it arrives. Apple's
hardware decoder rejects this camera's stream (CAVLC with custom scaling
matrices), so decoding happens in software, about 1.5 ms a frame.

The movie recorder keeps a table of 60 frame descriptors, 244 bytes apart
from 0xa07e5180: number and address at +4 and +8, timestamp (90 kHz) and
size at -52 and -48, placeholder size 0xbf440 while a frame is encoded.
Frames sit back to back in a ring from 0xa52b1c00, wrapping to its start.
The table lags behind the encoder (up to 400 ms, once every 60 frames) and
can describe a frame from an earlier lap, so it is only a hint here. Each
frame is checked by content: its header must follow the previous frame's
(picture timing and frame number), and it ends where a header that
follows it begins.
"""
import argparse
import signal
import sys
import time

import av
import numpy as np

sys.path.insert(0, __import__('os').path.dirname(__file__))
import ptp  # noqa: E402

TABLE, ENTRIES, ENTRY = 0xA07E5180, 60, 0xF4
IN_PROGRESS = 0xBF440
RING_LO, RING_HI = 0xA52B1C00, 0xA5611380
SCAN = 0x60000       # bytes to search for the end of a frame
HEAD = 1024          # bytes of a frame that identify it
WRAP_ROOM = 0x100000  # the encoder wraps with 0x95000-0xc4000 bytes left
AUD = b'\x00\x00\x00\x01\x09'


def sizes(cam):
    """{address: size} of the finished frames the table lists (hints only),
    oldest first."""
    start = TABLE - 52
    raw = cam.transact(ptp.PEEK, (start, ENTRIES * ENTRY + 52), timeout=5000)[2]
    words = np.frombuffer(raw, '<u4')
    found = []
    for k in range(ENTRIES):
        base = (52 + k * ENTRY) // 4
        number, address, size = int(words[base + 1]), int(words[base + 2]), int(words[base - 12])
        if number and RING_LO <= address < RING_HI and 0 < size < IN_PROGRESS:
            found.append((number, address, size))
    return {address: size for _, address, size in sorted(found)}


def read(cam, address, size):
    """Read `size` bytes at a possibly odd address (USB transfers need even ones)."""
    start = address & ~1
    length = (address + size - start + 1) & ~1
    data = cam.transact(ptp.PEEK, (start, length), timeout=5000)[2]
    return data[address - start:address - start + size]


class Header:
    """The fields of a frame's first bytes that tell consecutive frames apart."""

    def __init__(self, data):
        self.ok = data.startswith(AUD)
        self.cpb = self.frame_num = self.idr = None
        if not self.ok:
            return
        sei = data.find(b'\x00\x00\x00\x01\x06\x01\x09', 0, 1024)   # picture timing
        if sei >= 0:
            raw = data[sei + 7:sei + 16].replace(b'\x00\x00\x03', b'\x00\x00')
            self.cpb = int.from_bytes(raw[:4], 'big')       # +2 a frame, 2..60
        for start in range(5, min(len(data), 1024) - 5):
            if data[start:start + 4] == b'\x00\x00\x00\x01' and data[start + 4] & 0x1F in (1, 5):
                self.idr = data[start + 4] & 0x1F == 5
                rbsp = data[start + 5:start + 16].replace(b'\x00\x00\x03', b'\x00\x00')
                bits = ''.join(f'{b:08b}' for b in rbsp)
                i = 0
                for _ in range(3):                           # first_mb, slice_type, pps_id
                    zeros = bits.index('1', i) - i
                    i += 2 * zeros + 1
                self.frame_num = int(bits[i:i + 4], 2)       # log2_max_frame_num = 4
                break

    def follows(self, before):
        """Whether this frame comes right after `before` (not stale data)."""
        if not (self.ok and before and before.cpb is not None and self.cpb is not None):
            return False
        if self.cpb != (2 if before.cpb >= 60 else before.cpb + 2):
            return False
        return self.frame_num == (0 if self.idr else (before.frame_num + 1) % 16)


def take(cam, starts, before, hints, sent):
    """(address, bytes, header) of the next frame, or None if it isn't ready.

    The frame starts at one of `starts` (right after the previous frame, or
    at the ring start when the encoder wrapped) and must follow `before`
    (or, with no `before`, be a keyframe). It ends where the next frame's
    header, which must follow it in turn, begins: the table's size is tried
    first, then the data is searched. When the next frame wrapped to the
    ring start, only the table's size says where this one ends.

    Picture timing and frame number repeat every 30 frames, about one lap
    of the ring, so they alone can't tell a new frame from the one left
    there a lap earlier. `sent` holds the first bytes of each frame already
    sent, by address; a frame that matches them is left over, not new.
    """
    def new_header(address, head):
        return Header(head) if sent.get(address) != head[:HEAD] else None

    for start in starts:
        header = new_header(start, read(cam, start, HEAD))
        if header and (header.follows(before) if before else header.idr):
            break
    else:
        return None
    hint = hints.get(start)
    if hint:
        data = read(cam, start, hint + HEAD)
        candidates = [(start + hint, data[hint:])]
        if RING_HI - (start + hint) < WRAP_ROOM:
            candidates.append((RING_LO, None))
        for nxt, head in candidates:
            after = new_header(nxt, head or read(cam, nxt, HEAD))
            if after and after.follows(header):
                return start, data[:hint], header
    # Without a size, the frame ends at the next delimiter, which can't
    # appear inside a frame. If the frame there doesn't follow this one, the
    # encoder hasn't written it yet and what's there is left over from an
    # earlier lap; searching further would find old frames.
    data = read(cam, start, min(SCAN, RING_HI - start))
    at = data.find(AUD, 5)
    if at < 0:
        return None
    after = new_header(start + at, data[at:at + HEAD])
    if after and after.follows(header):
        return start, data[:at], header
    return None


def ue(value):
    """Exp-Golomb code for an unsigned value, as a bit string."""
    code = bin(value + 1)[2:]
    return '0' * (len(code) - 1) + code


def low_delay_sps(nal):
    """Declare in the SPS that frames are never reordered.

    The camera's SPS leaves out the bitstream restriction fields, so
    decoders assume the worst case and hold back up to 16 frames (about
    half a second) before showing anything. The camera never reorders
    frames (no B-frames, picture order type 2), so add the fields with no
    reordering and a one-frame buffer. Returns the NAL unchanged if it
    doesn't end in an unset bitstream_restriction_flag.
    """
    rbsp = nal.replace(b'\x00\x00\x03', b'\x00\x00')
    bits = ''.join(f'{b:08b}' for b in rbsp)
    stop = bits.rindex('1')                  # rbsp_stop_one_bit
    if bits[stop - 1] != '0':
        return nal
    fields = ('1' + ue(2) + ue(1) + ue(16) + ue(16)   # mv over boundaries, byte/bit limits, mv lengths
              + ue(0) + ue(1))                         # max_num_reorder_frames, max_dec_frame_buffering
    bits = bits[:stop - 1] + '1' + fields + '1'
    bits += '0' * (-len(bits) % 8)
    raw = bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))
    out = bytearray()
    zeros = 0
    for b in raw:                            # emulation prevention
        if zeros >= 2 and b <= 3:
            out.append(3)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def patch_frame(data):
    """Rewrite the SPS in a keyframe with low_delay_sps."""
    start = data.find(b'\x00\x00\x00\x01\x67')
    if start < 0:
        return data
    end = data.find(b'\x00\x00\x00\x01', start + 4)
    return data[:start + 4] + low_delay_sps(data[start + 4:end]) + data[end:]


def nv12(picture):
    """A decoded full-range 4:2:0 picture as NV12 bytes (Y plane, then Cb Cr pairs)."""
    w, h = picture.width, picture.height
    planes = [np.frombuffer(p, np.uint8).reshape(-1, p.line_size) for p in picture.planes]
    y = planes[0][:h, :w]
    cbcr = np.stack([planes[1][:h // 2, :w // 2], planes[2][:h // 2, :w // 2]], -1)
    return y.tobytes() + cbcr.tobytes()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('-o', '--out', help='write to a file instead of stdout')
    p.add_argument('--raw', action='store_true', help='write decoded NV12 frames instead of H.264')
    p.add_argument('--seconds', type=float, help='stop after this long')
    args = p.parse_args()

    out = open(args.out, 'wb') if args.out else sys.stdout.buffer
    cam = ptp.Camera()
    cam.open()

    # Finish the current transfer before exiting; see live.py.
    stopping = False

    def stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    decoder = None
    if args.raw:
        decoder = av.CodecContext.create('h264', 'r')
        decoder.flags |= av.codec.context.Flags.low_delay
        decoder.thread_count = 1
    header, end, count, began, last_frame = None, None, 0, time.time(), time.time()
    sent = {}
    try:
        while not stopping and not (args.seconds and time.time() - began > args.seconds):
            hints = sizes(cam)
            if header is None:
                # Start from a recent keyframe the table lists.
                starts = list(hints)[-20:][::-1]
            else:
                starts = (end, RING_LO)
            progressed = False
            while (frame := take(cam, starts, header, hints, sent)):
                address, data, header = frame
                sent[address] = data[:HEAD]
                if len(sent) > 200:
                    sent.pop(next(iter(sent)))
                end = address + len(data)
                starts = (end, RING_LO)
                data = patch_frame(data)
                if decoder:
                    for picture in decoder.decode(av.Packet(data)):
                        out.write(nv12(picture))
                else:
                    out.write(data)
                count += 1
                progressed = True
            if progressed:
                out.flush()
                last_frame = time.time()
            elif header and time.time() - last_frame > 1:
                # Nothing for a second: a new recording, or we lost track.
                print('starting again from the next keyframe', file=sys.stderr)
                header = None
            else:
                time.sleep(0.003)
    except BrokenPipeError:
        pass
    finally:
        cam.close()
        if args.out:
            out.close()
        rate = count / (time.time() - began)
        print(f'{count} frames, {rate:.1f} per second', file=sys.stderr)


if __name__ == '__main__':
    main()
