"""Stream the camera's H.264 video over USB while it records a movie.

Needs the usb-tools firmware, the camera in shooting mode with USB
connected (`uv run scripts/ptp.py shoot`), and a movie recording. Writes a
raw H.264 stream (Annex B) to stdout or a file:

  uv run scripts/stream.py | ffplay -fflags nobuffer -flags low_delay -f h264 -
  uv run scripts/stream.py -o clip.h264 --seconds 10

The movie recorder keeps a table of 60 frame descriptors, 244 bytes apart
from 0xa07e5180. Each frame's number and address are at +4 and +8, and
its timestamp (90 kHz) and size at -52 and -48. The frame being encoded has
the placeholder size 0xbf440. Frames sit in a ring from 0xa52b1c00 and
start with an access unit delimiter; keyframes carry the SPS and PPS.
"""
import argparse
import signal
import sys
import time

import numpy as np

sys.path.insert(0, __import__('os').path.dirname(__file__))
import ptp  # noqa: E402

TABLE, ENTRIES, ENTRY = 0xA07E5180, 60, 0xF4
IN_PROGRESS = 0xBF440
RING_LO, RING_HI = 0xA52B1C00, 0xA5611380
SETTLE = 0.005  # seconds after the next frame starts before reading one
FRAME_TICKS = 3003   # 90 kHz ticks per frame at 29.97 frames per second
AUD = b'\x00\x00\x00\x01\x09'


def frames(cam):
    """Frames in the table as {number: (address, size, finished, timestamp)}.

    Includes the frame being encoded, whose address is already set."""
    start = TABLE - 52
    raw = cam.transact(ptp.PEEK, (start, ENTRIES * ENTRY + 52), timeout=5000)[2]
    words = np.frombuffer(raw, '<u4')
    out = {}
    for k in range(ENTRIES):
        base = (52 + k * ENTRY) // 4
        number, address = int(words[base + 1]), int(words[base + 2])
        size, stamp = int(words[base - 12]), int(words[base - 13])
        if number and RING_LO <= address < RING_HI and 0 < size <= IN_PROGRESS:
            out[number] = (address, size, size != IN_PROGRESS, stamp)
    return out


def read(cam, address, size):
    """Read `size` bytes at a possibly odd address (USB transfers need even ones)."""
    start = address & ~1
    length = (address + size - start + 1) & ~1
    data = cam.transact(ptp.PEEK, (start, length), timeout=5000)[2]
    return data[address - start:address - start + size]


def is_keyframe(data):
    # Access unit delimiter (00 00 00 01 09 xx), then an SPS (NAL type 7).
    return len(data) > 11 and data[10] & 0x1F == 7


def next_frame(cam, listed, seen, number, prev, now, settle):
    """(address, timestamp, bytes) of frame `number`, or None if not ready.

    `prev` is (end address, timestamp) of the frame before it, or None.

    Entries can lag behind the encoder. Once per pass through the table an
    entry's number is updated before the rest of it, so for a while it
    describes the frame from 60 frames earlier, and a finished frame's size
    can still be corrected afterwards. A frame is only taken when its entry
    and the next one agree with each other:

    - its timestamp is one frame (3003 ticks at 90 kHz) after the previous
      frame's, and it starts where the previous frame ended (or at the
      ring start, after a wrap);
    - the next frame has started, with the following timestamp, exactly
      where this frame's size says it ends (or at the ring start).

    Nearly every frame passes as soon as the next one starts, about one
    frame (33 ms) behind the encoder.
    """
    this, following = listed.get(number), listed.get(number + 1)
    if not this or not following or now - seen[number + 1] < settle:
        return None
    address, size, finished, stamp = this
    if prev:
        end, prev_stamp = prev
        if abs(stamp - prev_stamp - FRAME_TICKS) > 9 or address not in (end, RING_LO):
            return None
    if abs(following[3] - stamp - FRAME_TICKS) > 9:
        return None
    if following[0] != address + size and not (following[0] == RING_LO and finished):
        return None
    if not 0 < size < IN_PROGRESS:
        return None
    data = read(cam, address, size)
    return (address, stamp, data) if data.startswith(AUD) else None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('-o', '--out', help='write to a file instead of stdout')
    p.add_argument('--seconds', type=float, help='stop after this long')
    p.add_argument('--settle', type=float, default=SETTLE,
                   help='seconds to wait after the next frame starts (default %(default)s)')
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

    # The table lists 60 frames but the ring only holds about 45, so the
    # oldest entries point at data already overwritten. Start just before
    # the newest keyframe (one every 15 frames) instead of at the oldest.
    last, prev, seen = None, None, {}
    started, count, began = False, 0, time.time()
    try:
        while not stopping and not (args.seconds and time.time() - began > args.seconds):
            now = time.time()
            listed = frames(cam)
            for number in listed:
                seen.setdefault(number, now)
            newest = max(listed) if listed else 0
            if last is None:
                last = newest - 16
            progressed = False
            while True:
                frame = next_frame(cam, listed, seen, last + 1, prev, now, args.settle)
                if frame is None:
                    break
                address, stamp, data = frame
                last += 1
                seen.pop(last - 120, None)
                prev = (address + len(data), stamp)
                if not started:
                    if not is_keyframe(data):
                        continue
                    started = True
                out.write(data)
                count += 1
                progressed = True
            if progressed:
                out.flush()
            elif newest - last > 30:
                # The next frame never showed up, or we fell a second
                # behind: start again from the next keyframe.
                print(f'resync at frame {newest}', file=sys.stderr)
                last, started, prev = newest - 2, False, None
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
