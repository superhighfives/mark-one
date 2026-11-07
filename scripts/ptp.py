"""Talk to the E-M5 over USB with raw PTP.

Set the camera's USB mode to MTP (Custom menu, USB Mode), connect it, then:

  uv run scripts/ptp.py info                      # model, firmware, commands
  uv run scripts/ptp.py peek 0x602adef8 4         # read camera memory
  uv run scripts/ptp.py peek 0xbd742b00 1572864 -o frame.yuv

`peek` needs the usb-peek patch (command 0x9484). macOS's ptpcamerad grabs
cameras as soon as they connect; the script stops it and takes the camera.
"""
import argparse
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
PEEK = 0x9484
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

    def transact(self, code, params=(), timeout=5000):
        """Send a command, read any data phase, and return (response code, data)."""
        self.tid += 1
        header = struct.pack('<IHHI', 12 + 4 * len(params), CMD, code, self.tid)
        self.out.write(header + b''.join(struct.pack('<I', p) for p in params), timeout)

        data = b''
        while True:
            packet = bytes(self.inp.read(512 * 1024, timeout))
            length, kind, rcode, _ = struct.unpack_from('<IHHI', packet)
            if kind == RESP:
                return rcode, data
            # A data container may span several reads.
            body = packet[12:]
            while len(body) < length - 12:
                body += bytes(self.inp.read(512 * 1024, timeout))
            data += body[:length - 12]

    def open(self):
        code, _ = self.transact(OPEN_SESSION, (1,))
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
    code, d = cam.transact(GET_DEVICE_INFO)
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
    print('peek (0x9484):', 'available' if PEEK in ops else 'not available')


def peek(cam, address, length, out):
    if length % 2:
        sys.exit('Length must be even.')
    code, data = cam.transact(PEEK, (address, length), timeout=20000)
    if code != OK:
        sys.exit(f'peek failed: {code:#06x}')
    if out:
        open(out, 'wb').write(data)
        print(f'wrote {len(data)} bytes to {out}')
    else:
        for i in range(0, len(data), 16):
            row = data[i:i + 16]
            print(f'{address + i:08x}  {row.hex(" ")}')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    sub.add_parser('info')
    pk = sub.add_parser('peek')
    pk.add_argument('address', type=lambda s: int(s, 0))
    pk.add_argument('length', type=lambda s: int(s, 0))
    pk.add_argument('-o', '--out')
    args = p.parse_args()

    cam = Camera()
    cam.open()
    try:
        if args.cmd == 'info':
            info(cam)
        else:
            peek(cam, args.address, args.length, args.out)
    finally:
        cam.close()


if __name__ == '__main__':
    main()
