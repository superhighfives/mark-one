"""Talk to the E-M5 over USB with raw PTP.

Set the camera's USB mode to MTP (Custom menu, USB Mode), connect it, then:

  uv run scripts/ptp.py info                      # model, firmware, commands
  uv run scripts/ptp.py peek 0x602adef8 4         # read camera memory
  uv run scripts/ptp.py peek 0xbd742b00 1572864 -o frame.yuv
  uv run scripts/ptp.py poke 0x7e400000 code.bin  # write camera memory
  uv run scripts/ptp.py run 0x7e400000 1 2        # call a function
  uv run scripts/ptp.py shoot                     # live view with USB connected
  uv run scripts/ptp.py output evf                # 800x600 live view instead of 568x480
  uv run scripts/ptp.py trace                     # print what the mode manager logs
  uv run scripts/ptp.py versions                  # firmware versions (needs the webcam patch)
  uv run scripts/ptp.py update E0972300.BIN       # install firmware over USB

`peek`, `poke` and `run` need the usb-tools patch (commands 0x9484-0x9486).
USB transfers only reach the uncached view of RAM, so addresses in
0x40000000-0x7fffffff are moved to their uncached mirror, 0x40000000 higher.
`run` takes the address as given: code runs from the cached view, and the
target must set up its own stack frame (see asm/usb.s).

macOS's ptpcamerad grabs cameras as soon as they connect; the script stops
it and takes the camera.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import time

import libusb_package
import usb.core
import usb.util

OLYMPUS_VENDOR = 0x07B4
PTP_CLASS = 6

CMD, DATA, RESP = 1, 2, 3
OPEN_SESSION = 0x1002
CLOSE_SESSION = 0x1003
GET_DEVICE_INFO = 0x1001
PEEK, POKE, RUN = 0x9484, 0x9485, 0x9486
PEEK_CHUNK = 0x180000   # 36 MB/s measured; 64 KB chunks manage 20
POKE_CHUNK = 0x10000
OK = 0x2001


def claim(dev, intf):
    """Claim the PTP interface, taking it from macOS's camera service if needed.

    ptpcamerad claims every PTP camera as soon as it connects, and launchd
    restarts it within a fraction of a second of being stopped. Stop it, then
    retry the claim until it lands in the gap before the restart.
    """
    try:
        usb.util.claim_interface(dev, intf)
        return
    except usb.core.USBError:
        pass
    subprocess.run(['killall', '-9', 'ptpcamerad'], capture_output=True)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            usb.util.claim_interface(dev, intf)
            return
        except usb.core.USBError:
            time.sleep(0.005)
    sys.exit('Could not claim the camera. Quit Photos and Image Capture and try again.')


class Camera:
    def __init__(self):
        dev = usb.core.find(idVendor=OLYMPUS_VENDOR, backend=libusb_package.get_libusb1_backend())
        if dev is None:
            sys.exit('No Olympus camera found. Is it on, connected, and set to MTP?')
        # Linux needs the kernel driver detached. macOS only allows that as
        # root, and claiming the interface works there without it.
        try:
            if dev.is_kernel_driver_active(0):
                dev.detach_kernel_driver(0)
        except (usb.core.USBError, NotImplementedError):
            pass
        try:
            dev.set_configuration()
        except usb.core.USBError:
            pass  # already configured
        intf = dev.get_active_configuration()[(0, 0)]
        if intf.bInterfaceClass != PTP_CLASS:
            sys.exit(f'Interface class is {intf.bInterfaceClass}, not PTP. Set USB Mode to MTP.')
        claim(dev, intf)

        def ep(direction, kind):
            return usb.util.find_descriptor(
                intf, custom_match=lambda e:
                usb.util.endpoint_direction(e.bEndpointAddress) == direction
                and usb.util.endpoint_type(e.bmAttributes) == kind)

        self.dev = dev
        self.out = ep(usb.util.ENDPOINT_OUT, usb.util.ENDPOINT_TYPE_BULK)
        self.inp = ep(usb.util.ENDPOINT_IN, usb.util.ENDPOINT_TYPE_BULK)
        self.tid = 0

    def transact(self, code, params=(), data_out=None, timeout=5000):
        """Run one command. Returns (response code, response params, data in)."""
        self.tid += 1
        header = struct.pack('<IHHI', 12 + 4 * len(params), CMD, code, self.tid)
        self.out.write(header + b''.join(struct.pack('<I', p) for p in params), timeout)
        if data_out is not None:
            self.out.write(struct.pack('<IHHI', 12 + len(data_out), DATA, code, self.tid) + data_out, timeout)

        data = b''
        while True:
            packet = bytes(self.inp.read(512 * 1024, timeout))
            length, kind, rcode, _ = struct.unpack_from('<IHHI', packet)
            if kind == RESP:
                n = (length - 12) // 4
                return rcode, struct.unpack_from(f'<{n}I', packet, 12), data
            # A data container may span several reads.
            body = packet[12:]
            while len(body) < length - 12:
                body += bytes(self.inp.read(512 * 1024, timeout))
            data += body[:length - 12]

    def open(self):
        try:
            code, _, _ = self.transact(OPEN_SESSION, (1,))
        except (usb.core.USBTimeoutError, usb.core.USBError):
            # A transfer cut off halfway (a killed script, for example)
            # leaves the camera mid-command. Read and drop whatever it still
            # wants to send, then try again. Don't reset the device: in
            # shooting mode the camera drops off USB and doesn't come back
            # until the cable is replugged.
            self.drain()
            code, _, _ = self.transact(OPEN_SESSION, (1,))
        if code not in (OK, 0x201E):  # 0x201E: session already open
            sys.exit(f'OpenSession failed: {code:#06x}')

    def drain(self):
        for ep in (self.inp, self.out):
            try:
                self.dev.clear_halt(ep)
            except usb.core.USBError:
                pass
        while True:
            try:
                self.inp.read(512 * 1024, 300)
            except usb.core.USBError:
                return

    def close(self):
        self.transact(CLOSE_SESSION)


def ptp_string(buf, off):
    n = buf[off]
    s = buf[off + 1:off + 1 + 2 * n].decode('utf-16-le').rstrip('\0')
    return s, off + 1 + 2 * n


def ptp_u16_array(buf, off):
    (n,) = struct.unpack_from('<I', buf, off)
    return list(struct.unpack_from(f'<{n}H', buf, off + 4)), off + 4 + 2 * n


def info(cam):
    code, _, d = cam.transact(GET_DEVICE_INFO)
    off = 8
    _, off = ptp_string(d, off)            # vendor extension description
    off += 2                               # functional mode
    ops, off = ptp_u16_array(d, off)
    _, off = ptp_u16_array(d, off)         # events
    _, off = ptp_u16_array(d, off)         # device properties
    _, off = ptp_u16_array(d, off)         # capture formats
    _, off = ptp_u16_array(d, off)         # image formats
    maker, off = ptp_string(d, off)
    model, off = ptp_string(d, off)
    version, off = ptp_string(d, off)
    print(f'{maker} {model}, firmware {version}')
    print('commands:', ' '.join(f'{o:04x}' for o in ops))
    for name, op in (('peek', PEEK), ('poke', POKE), ('run', RUN)):
        print(f'{name} ({op:#06x}):', 'available' if op in ops else 'not available')


def uncached(address):
    """The address USB transfers can reach for `address`."""
    if 0x40000000 <= address < 0x80000000:
        return address + 0x40000000
    return address


def peek(cam, address, length, out):
    if length % 2 or address % 2:
        sys.exit('Address and length must be even.')
    start = uncached(address)
    data = b''
    while len(data) < length:
        n = min(PEEK_CHUNK, length - len(data))
        code, _, chunk = cam.transact(PEEK, (start + len(data), n), timeout=20000)
        if code != OK:
            sys.exit(f'peek failed at {start + len(data):#010x}: {code:#06x}')
        data += chunk
    if out:
        open(out, 'wb').write(data)
        print(f'wrote {len(data)} bytes to {out}')
    else:
        for i in range(0, len(data), 16):
            row = data[i:i + 16]
            print(f'{address + i:08x}  {row.hex(" ")}')


def poke(cam, address, data, quiet=False):
    if len(data) % 2 or address % 2:
        sys.exit('Address and length must be even.')
    start = uncached(address)
    for off in range(0, len(data), POKE_CHUNK):
        code, _, _ = cam.transact(POKE, (start + off,), data_out=data[off:off + POKE_CHUNK], timeout=20000)
        if code != OK:
            sys.exit(f'poke failed at {start + off:#010x}: {code:#06x}')
    if not quiet:
        print(f'wrote {len(data)} bytes at {address:#010x}')


# Two helpers for reading and writing through the CPU cache, which USB
# transfers can't reach. They go in the unused end of the usb-tools handler
# space (0x7eaaab74-0x7eaaab8e) and are called with `run`, address in a0.
READ32 = 0x7EAAAB74     # mov (a0),d0; rets
WRITE32 = 0x7EAAAB7A    # mov d0,(a0); mov (a0),d0; rets
HELPERS = bytes.fromhex('70f0fccbcbcb' '6070f0fccbcb')


def install_helpers(cam):
    poke(cam, READ32, HELPERS, quiet=True)


def read32(cam, address):
    return call(cam, READ32, (0, 0, address))[0]


def write32(cam, address, value):
    return call(cam, WRITE32, (value, 0, address))[0]


def call(cam, function, args):
    code, params, _ = cam.transact(RUN, (function, *args), timeout=20000)
    if code != OK:
        sys.exit(f'run failed: {code:#06x}')
    return params


# Changes to the running firmware for streaming, as {address: (stock bytes,
# patched bytes)}. Only in memory; a restart undoes them. Stock code longer
# than 8 bytes is given as (length, sha256).
RUNTIME_PATCHES = {
    # Movie recording skips writing video to the card. The movie writers
    # call fileif_fwrite (0x7e69f3bb) from QT_FILE at 0x7e7a75b2 and
    # MOV_FILE at 0x7e7c04ca, each `call fwrite,[],24` followed by a check
    # that the returned count equals the requested size (in d1). Replace
    # each call with `mov d1,d0` (report the full size as written) and nops.
    'card writes': {
        0x7E7A75B2: ('dd097eefff001883', '84cbcbcbcbcbcb83'),
        0x7E7C04CA: ('ddf1eeedff001882', '84cbcbcbcbcbcb82'),
    },
    # Recording time limit. 0x7e7bbe71 works out how long a movie can run:
    # the smaller of the format's maximum (1740 s for MOV Full HD and HD,
    # 0x7e7bbf89: `mov 1740,a3`) and what the card's free space allows.
    # Raise the maximum to 32767 s (about 9 hours) and use it for both the
    # limit and the card figure, since the card isn't written.
    'time limit': {
        0x7E7BBF88: ('0427cc06', '0427ff7f'),
        0x7E7BBFBC: ((12, '5c7993277f758597d2e77926f35759decab9140c60a08c80b6b1b227a5f73d6e'), 'f1dc8283cbcbcbcbcbcbcb5c'),
    },
}


def apply_runtime_patches(cam):
    """Apply RUNTIME_PATCHES, checking each spot still holds the stock bytes."""
    for name, patches in RUNTIME_PATCHES.items():
        for address, (stock, patched) in patches.items():
            start = address & ~1
            length = stock[0] if isinstance(stock, tuple) else len(stock) // 2
            current = cam.transact(PEEK, (uncached(start), length))[2].hex()
            if isinstance(stock, tuple):
                matches = hashlib.sha256(bytes.fromhex(current)).hexdigest() == stock[1]
            else:
                matches = current == stock
            if matches:
                poke(cam, address, bytes.fromhex(patched), quiet=True)
            elif current != patched:
                sys.exit(f'{name}: unexpected code at {address:#010x}: {current}')


def shoot(cam):
    """Switch the camera from PC mode to shooting, keeping USB connected.

    A computer asking for camera control sends PC mode the events
    0x03000048-0x0300004b, which `startCameraControl` turns into the dormant
    PC_CAM_SHOOTING mode change. Only PC sub-state 0x6004 handles them, and an
    MTP connection uses 0x6005, so point 0x6005 at 0x6004's event list (a
    superset of its own) and then post the event the way the serial console's
    `nfPcCbk 50 1` does. Also applies RUNTIME_PATCHES: movies don't write
    the card and have no 29-minute limit, and lets the power switch turn
    the camera off. A restart undoes all of it.
    """
    install_helpers(cam)
    apply_runtime_patches(cam)
    write32(cam, 0x7EEF375C, 0x7EEF30EC)    # sub-state 0x6005: event list...
    write32(cam, 0x7EEF3760, 8)             # ...and its length
    write32(cam, 0x7EEEA8B0, 0x7EDC726A)    # power switch: see NOTES.md
    pc = read32(cam, 0x605F0D3C)            # PC mode object
    call(cam, 0x7EDD55BA, (2, 50, pc, 1))   # notification 50, value 1
    print('requested shooting mode')


OUTPUTS = {'lcd': 0x01, 'evf': 0x10}   # CameraCommon::changeOutLine lines


def output(cam, name):
    """Send live view to the rear screen or the built-in viewfinder.

    The screen buffer holds whatever the active display needs: 568x480 for
    the rear screen, 800x600 (800x450 in movie mode) for the viewfinder.
    """
    install_helpers(cam)
    api = read32(cam, 0x602B243C)                   # CameraCommon API object
    change_out_line = read32(cam, read32(cam, api) + 16)
    result = call(cam, change_out_line, (OUTPUTS[name], 0, api))[0]
    if result:
        sys.exit(f'changeOutLine failed: {result:#010x}')
    print(f'output: {name}')


# asm/trace.s: records the mode manager's log messages in a ring that a
# peek can read. TRACE_HOOKS replace the start of its two loggers with
# jumps to the stub, as {address: (stock bytes, patched bytes)}; each
# covers whole even addresses because pokes need them.
TRACE = 0x7EAB0390
TRACE_CODE = bytes.fromhex(
    '979200cd2700000098dd349f32008008dc4a9e3200829792cd1200000098dd1f9f32008008dc4b9e3200'
    'fcdcdc03abbe74f1e54464f1d5f8e11f55e5fcdde003abbef165f01df81104df0000')
TRACE_COUNT, TRACE_RING, TRACE_SIZE = 0x7EAB03DC, 0x7EAB03E0, 32
TRACE_HOOKS = {
    0x7EDDA1E2: ('0c9792cde8008008', '0cdcad61cdff8008'),   # 0x7edda1e3: jmp 0x7eab0390
    0x7EDDA1F8: ('829792cdd2008008', 'dcad61cdff008008'),   # 0x7edda1f8: jmp 0x7eab03a5
}
CURRENT_REQUEST = 0x602B4A90        # the mode manager's last mode change request
FIRMWARE = range(0x7E421020, 0x7F200000)


def trace(cam, seconds):
    """Print the mode manager's log messages as they happen.

    Shows every state handler, mode change request, refusal and incoming
    system event (with its number), which tells what the camera does with
    an event such as the power switch. Stays until the camera restarts.
    """
    install_helpers(cam)
    if cam.transact(PEEK, (uncached(TRACE), len(TRACE_CODE)))[2] != TRACE_CODE:
        poke(cam, TRACE_COUNT, bytes(4), quiet=True)
        poke(cam, TRACE, TRACE_CODE, quiet=True)
    for address, (stock, patched) in TRACE_HOOKS.items():
        current = cam.transact(PEEK, (uncached(address), len(stock) // 2))[2].hex()
        if current == stock:
            poke(cam, address, bytes.fromhex(patched), quiet=True)
        elif current != patched:
            sys.exit(f'unexpected code at {address:#010x}: {current}')
    names = {}

    def name(address):
        if address not in FIRMWARE:
            return f'{address:#010x}'
        if address not in names:
            raw = cam.transact(PEEK, (uncached(address & ~1), 80))[2][address & 1:]
            names[address] = raw.split(b'\0')[0].decode('latin-1')
        return names[address]

    def count():
        return struct.unpack('<I', cam.transact(PEEK, (uncached(TRACE_COUNT), 4))[2])[0]

    seen = count()
    request = read32(cam, CURRENT_REQUEST)
    print(f'tracing; mode change request {request}')
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        now = count()
        if now - seen > TRACE_SIZE:
            print(f'... {now - seen - TRACE_SIZE} messages lost')
            seen = now - TRACE_SIZE
        if now != seen:
            ring = struct.unpack(f'<{2 * TRACE_SIZE}I', cam.transact(PEEK, (uncached(TRACE_RING), 8 * TRACE_SIZE))[2])
            for k in range(seen, now):
                message, number = ring[2 * (k % TRACE_SIZE)], ring[2 * (k % TRACE_SIZE) + 1]
                print(f'{time.strftime("%H:%M:%S")}  {name(message)}' + (f' {number:#x}' if number else ''))
            seen = now
        latest = read32(cam, CURRENT_REQUEST)
        if latest != request:
            print(f'mode change request {request} -> {latest}')
            request = latest
        time.sleep(0.05)


def run(cam, function, args):
    code, params, _ = cam.transact(RUN, (function, *args), timeout=20000)
    if code != OK:
        sys.exit(f'run failed: {code:#06x}')
    print(f'd0 = {params[0]:#010x}  a0 = {params[1]:#010x}')


GET_UPDATE_MODE, GET_VERSIONS, FIRM_INFO, SEND_PIECE, CHECK_FIRM, UPDATE_STATUS, START_UPDATE = (
    0x911C, 0x9120, 0x9125, 0x9119, 0x9121, 0x9122, 0x9123)
PIECE = 0xF800


def versions(cam):
    """Print the update mode and the body and lens versions (read only)."""
    code, params, _ = cam.transact(GET_UPDATE_MODE)
    print(f'update mode: {code:#06x} {[hex(p) for p in params]}')
    code, _, data = cam.transact(GET_VERSIONS)
    if code != OK:
        sys.exit(f'GetVersions failed: {code:#06x}')
    (n,), off = struct.unpack_from('<I', data), 4
    for _ in range(n):
        s, off = ptp_string(data, off)
        print(s)


def update(cam, path):
    """Install a firmware file over USB, the way OM Workspace does."""
    firm = open(path, 'rb').read()
    code, params, _ = cam.transact(GET_UPDATE_MODE)
    if code != OK or params[:1] != (1,):
        sys.exit(f'The camera is not ready to update: {code:#06x} {params}')
    info = struct.pack('<IHHI', 0x80000001, 0xB001, 0, len(firm)) + bytes(48)
    code, params, _ = cam.transact(FIRM_INFO, (0x80000001,), data_out=info)
    if code != OK:
        sys.exit(f'SendFirmDataInfo failed: {code:#06x} {params}')
    for offset in range(0, len(firm), PIECE):
        piece = firm[offset:offset + PIECE]
        code, _, _ = cam.transact(SEND_PIECE, (offset, len(piece)), data_out=piece)
        if code != OK:
            sys.exit(f'sending failed at {offset:#x}: {code:#06x}')
        print(f'\rsent {offset + len(piece)} of {len(firm)} bytes', end='', flush=True)
    print()
    code, params, _ = cam.transact(CHECK_FIRM)
    if code != OK:
        sys.exit(f'FirmwareCheck failed: {code:#06x} {params}')
    deadline = time.monotonic() + 180
    while True:
        code, params, _ = cam.transact(UPDATE_STATUS)
        print(f'status {code:#06x} {params}')
        if code != OK or params[:1] not in ((1,), (2,)):
            sys.exit('The camera rejected the firmware. Nothing was installed.')
        if params[0] == 2:
            break
        if time.monotonic() > deadline:
            sys.exit('The camera never finished checking the firmware. Nothing was installed.')
        time.sleep(1)
    code, params, _ = cam.transact(START_UPDATE)
    print(f'start: {code:#06x} {params}')
    print('The camera is installing. Its screen shows an animation, then OK.')
    print('When it shows OK, switch the camera off and on.')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('info')
    pk = sub.add_parser('peek')
    pk.add_argument('address', type=lambda s: int(s, 0))
    pk.add_argument('length', type=lambda s: int(s, 0))
    pk.add_argument('-o', '--out')
    po = sub.add_parser('poke')
    po.add_argument('address', type=lambda s: int(s, 0))
    po.add_argument('data', help='a file, or hex bytes like 0102abcd')
    sub.add_parser('shoot', help='switch to shooting mode with USB connected')
    out = sub.add_parser('output', help='send live view to the rear screen or viewfinder')
    out.add_argument('name', choices=sorted(OUTPUTS))
    tr = sub.add_parser('trace', help="print the mode manager's log messages")
    tr.add_argument('seconds', type=float, nargs='?', default=120)
    sub.add_parser('versions', help='print the firmware versions the camera reports (read only)')
    up = sub.add_parser('update', help='install a firmware file over USB')
    up.add_argument('file')
    up.add_argument('--yes', action='store_true', help="don't ask before installing")
    ru = sub.add_parser('run')
    ru.add_argument('function', type=lambda s: int(s, 0))
    ru.add_argument('args', nargs='*', type=lambda s: int(s, 0), help='d0, d1, a0, a1')
    args = p.parse_args()
    if args.cmd == 'update' and not args.yes:
        print('This rewrites the camera\'s firmware. If it stops partway, the camera may not start.')
        if input('Type "install" to go ahead: ') != 'install':
            sys.exit('Cancelled.')

    cam = Camera()
    cam.open()
    try:
        if args.cmd == 'info':
            info(cam)
        elif args.cmd == 'peek':
            peek(cam, args.address, args.length, args.out)
        elif args.cmd == 'shoot':
            shoot(cam)
        elif args.cmd == 'trace':
            trace(cam, args.seconds)
        elif args.cmd == 'output':
            output(cam, args.name)
        elif args.cmd == 'versions':
            versions(cam)
        elif args.cmd == 'update':
            update(cam, args.file)
            return
        elif args.cmd == 'poke':
            data = open(args.data, 'rb').read() if os.path.exists(args.data) else bytes.fromhex(args.data)
            poke(cam, args.address, data)
        else:
            run(cam, args.function, args.args[:4])
    finally:
        try:
            cam.close()
        except usb.core.USBError:
            pass  # the camera restarts to install an update


if __name__ == '__main__':
    main()
