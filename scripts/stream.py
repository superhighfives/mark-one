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
LAG = 6     # frames; 3 leaves a few damaged blocks, 8 none


def frames(cam):
    """Finished frames in the table as (number, address, size), oldest first."""
    start = TABLE - 52
    raw = cam.transact(ptp.PEEK, (start, ENTRIES * ENTRY + 52), timeout=5000)[2]
    words = np.frombuffer(raw, '<u4')
    out = []
    for k in range(ENTRIES):
        base = (52 + k * ENTRY) // 4
        number, address, size = int(words[base + 1]), int(words[base + 2]), int(words[base - 12])
        if number and size != IN_PROGRESS and RING_LO <= address < RING_HI and 0 < size < IN_PROGRESS:
            out.append((number, address, size))
    return sorted(out)


def read(cam, address, size):
    """Read `size` bytes at a possibly odd address (USB transfers need even ones)."""
    start = address & ~1
    length = (address + size - start + 1) & ~1
    data = cam.transact(ptp.PEEK, (start, length), timeout=5000)[2]
    return data[address - start:address - start + size]


def is_keyframe(data):
    # Access unit delimiter (00 00 00 01 09 xx), then an SPS (NAL type 7).
    return len(data) > 11 and data[10] & 0x1F == 7


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('-o', '--out', help='write to a file instead of stdout')
    p.add_argument('--seconds', type=float, help='stop after this long')
    p.add_argument('--lag', type=int, default=LAG, help='frames to stay behind the encoder (default %(default)s)')
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
    finished = frames(cam)
    last = finished[-1][0] - 16 if finished else None
    started, count, began = False, 0, time.time()
    try:
        while not stopping and not (args.seconds and time.time() - began > args.seconds):
            # A frame's size is set before all its data has landed in
            # memory, so stay a few frames behind the newest (about 100 ms).
            listed = frames(cam)
            newest = listed[-1][0] if listed else 0
            new = [f for f in listed if (last is None or f[0] > last) and f[0] <= newest - args.lag]
            if not new:
                time.sleep(0.01)
                continue
            for number, address, size in new:
                data = read(cam, address, size)
                if not started:
                    if not is_keyframe(data):
                        last = number
                        continue
                    started = True
                out.write(data)
                last = number
                count += 1
            out.flush()
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
