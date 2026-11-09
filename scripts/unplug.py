"""Post the camera's "USB unplugged" event with the cable still in, and
trace what the mode manager does with it.

Unplugging the cable while Mark One uses the camera leaves the camera stuck
(NOTES.md, "Unplugging in webcam mode"). A real unplug leaves nothing to
read afterwards, so this sets the camera up the way Mark One does, starts
`ptp.py trace`'s logger, then calls the unplug callback itself:

  1. shooting mode with USB connected (`ptp.py shoot`)
  2. the mode dial forced to movie, the controls locked, as Mark One does
  3. a recording started with the REC key (unless --idle)
  4. the system event callback 0x7edd910c called with d1 = 9 (unplug) and
     a0 = its registered context, found by searching RAM for the callback
  5. the log printed for --seconds, then the state Mark One cares about

Needs the webcam firmware (usb-tools, key stub) and Mark One quit. The
camera is likely to be stuck afterwards; a battery pull clears it.

  uv run scripts/unplug.py                 # find the context, then post
  uv run scripts/unplug.py --find-only     # just search for the context
"""
import argparse
import struct
import sys
import time

sys.path.insert(0, sys.argv[0].rsplit('/', 1)[0])
import ptp  # noqa: E402

UNPLUG_CALLBACK = 0x7EDD910C
UNPLUG_EVENT = 9
SEARCH = (0x60000000, 0x60800000)       # data RAM: objects and their tables

COMMON = 0x602B243C                     # CameraCommon object pointer
SET_MODE_DIAL, GET_MODE_DIAL, MOVIE_DIAL = 0x7EAA71CD, 0x7EAA683F, 5
DIAL_OVERRIDE = 0x605AEDBC
CANCEL_KEYS, RESET_KEYS, KEY_LIST = 0x7EACB1A9, 0x7EACB21A, 0x7EAAF460
LOCKED_KEYS = [48, 49, 52, 53, 56, 57, 60, 61, 64, 65, 68, 69, 72, 73, 76, 77,
               80, 81, 84, 85, 88, 89, 92, 93, 96, 97, 100, 101, 120, 121, 127, 128]
KEY_STUB, REC = 0x7EAB0380, 0x1209
SEQUENCE = 0x602B1FF4                   # 0x10 while a movie records
CONNECTION = 0x605F0D14


def find_context(cam):
    """Search RAM for the registered unplug callback and its context."""
    start, end = SEARCH
    chunk = 0x100000
    hits = []
    for base in range(start, end, chunk):
        data = cam.transact(ptp.PEEK, (ptp.uncached(base), chunk), timeout=20000)[2]
        offset = data.find(struct.pack('<I', UNPLUG_CALLBACK))
        while offset != -1:
            if offset % 4 == 0:
                around = struct.unpack_from('<8I', data, max(0, offset - 16))
                hits.append((base + offset, around))
            offset = data.find(struct.pack('<I', UNPLUG_CALLBACK), offset + 1)
    for address, around in hits:
        print(f'{address:#010x}: ' + ' '.join(f'{w:08x}' for w in around))
    return hits


def set_up(cam, record):
    ptp.shoot(cam)
    time.sleep(1.5)
    common = ptp.read32(cam, COMMON)
    for _ in range(20):
        ptp.call(cam, SET_MODE_DIAL, (MOVIE_DIAL, 0, common))
        if ptp.call(cam, GET_MODE_DIAL, (0, 0, common))[0] == MOVIE_DIAL:
            break
        time.sleep(0.25)
    ptp.call(cam, RESET_KEYS, (0, 0, 0, 0))
    for index, key in enumerate(LOCKED_KEYS):
        ptp.write32(cam, KEY_LIST + 4 * index, key)
    ptp.call(cam, CANCEL_KEYS, (len(LOCKED_KEYS), 0, 0, KEY_LIST))
    if record:
        ptp.call(cam, KEY_STUB, (0x02000000 | REC, 0, 0, 0))
        time.sleep(0.5)
        ptp.call(cam, KEY_STUB, (0x02010000 | REC, 0, 0, 0))
        for _ in range(30):
            if ptp.read32(cam, SEQUENCE) == 0x10:
                break
            time.sleep(0.1)
    state(cam, 'set up')


def state(cam, label):
    print(f'{label}: sequence {ptp.read32(cam, SEQUENCE):#x}, dial override '
          f'{ptp.read32(cam, DIAL_OVERRIDE):#010x}, mode change request '
          f'{ptp.read32(cam, ptp.CURRENT_REQUEST)}, connection {ptp.read32(cam, CONNECTION)}')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--find-only', action='store_true', help='search for the context and stop')
    p.add_argument('--context', type=lambda s: int(s, 0), help='use this context instead of searching')
    p.add_argument('--idle', action='store_true', help="don't start a recording first")
    p.add_argument('--seconds', type=float, default=15, help='how long to print the log afterwards')
    args = p.parse_args()

    cam = ptp.Camera()
    cam.open()
    ptp.install_helpers(cam)
    context = args.context
    if context is None:
        hits = find_context(cam)
        if args.find_only:
            return
        if len(hits) != 1:
            sys.exit(f'found the callback {len(hits)} times; pass --context with the one to use')
        # The context is stored next to the callback; which side is the
        # first thing to confirm on the camera, so show it and ask.
        sys.exit('Check the words around the hit, then run again with --context.')
    set_up(cam, record=not args.idle)

    since = ptp.install_trace(cam)
    print(f'posting unplug: call {UNPLUG_CALLBACK:#010x} with a0 = {context:#010x}, d1 = {UNPLUG_EVENT}')
    try:
        ptp.call(cam, UNPLUG_CALLBACK, (0, UNPLUG_EVENT, context, 0))
    except Exception as error:  # noqa: BLE001
        print(f'the call failed: {error}')
    ptp.trace(cam, args.seconds, since=since)
    state(cam, 'afterwards')

if __name__ == '__main__':
    main()
