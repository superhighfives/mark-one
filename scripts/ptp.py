"""Talk to the E-M5 over USB with raw PTP.

Set the camera's USB mode to MTP (Custom menu, USB Mode), connect it, then:

  uv run scripts/ptp.py info                      # model, firmware, commands
  uv run scripts/ptp.py peek 0x602adef8 4         # read camera memory
  uv run scripts/ptp.py peek 0xbd742b00 1572864 -o frame.yuv
  uv run scripts/ptp.py poke 0x7e400000 code.bin  # write camera memory
  uv run scripts/ptp.py run 0x7e400000 1 2        # call a function

`peek`, `poke` and `run` need the usb-tools patch (commands 0x9484-0x9486).
USB transfers only reach the uncached view of RAM, so addresses in
0x40000000-0x7fffffff are moved to their uncached mirror, 0x40000000 higher.
`run` takes the address as given: code runs from the cached view, and the
target must set up its own stack frame (see asm/usb.s).

macOS's ptpcamerad grabs cameras as soon as they connect; the script stops
it and takes the camera.
"""
import argparse
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
CHUNK = 0x10000
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
        code, _, _ = self.transact(OPEN_SESSION, (1,))
        if code not in (OK, 0x201E):  # 0x201E: session already open
            sys.exit(f'OpenSession failed: {code:#06x}')

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
        n = min(CHUNK, length - len(data))
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


def poke(cam, address, data):
    if len(data) % 2 or address % 2:
        sys.exit('Address and length must be even.')
    start = uncached(address)
    for off in range(0, len(data), CHUNK):
        code, _, _ = cam.transact(POKE, (start + off,), data_out=data[off:off + CHUNK], timeout=20000)
        if code != OK:
            sys.exit(f'poke failed at {start + off:#010x}: {code:#06x}')
    print(f'wrote {len(data)} bytes at {address:#010x}')


def run(cam, function, args):
    code, params, _ = cam.transact(RUN, (function, *args), timeout=20000)
    if code != OK:
        sys.exit(f'run failed: {code:#06x}')
    print(f'd0 = {params[0]:#010x}  a0 = {params[1]:#010x}')


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
    ru = sub.add_parser('run')
    ru.add_argument('function', type=lambda s: int(s, 0))
    ru.add_argument('args', nargs='*', type=lambda s: int(s, 0), help='d0, d1, a0, a1')
    args = p.parse_args()

    cam = Camera()
    cam.open()
    try:
        if args.cmd == 'info':
            info(cam)
        elif args.cmd == 'peek':
            peek(cam, args.address, args.length, args.out)
        elif args.cmd == 'poke':
            data = open(args.data, 'rb').read() if os.path.exists(args.data) else bytes.fromhex(args.data)
            poke(cam, args.address, data)
        else:
            run(cam, args.function, args.args[:4])
    finally:
        cam.close()


if __name__ == '__main__':
    main()
