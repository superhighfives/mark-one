"""Show the camera's live view in a browser, over USB.

Needs the usb-tools firmware and the camera in shooting mode with USB
connected (`uv run scripts/ptp.py shoot`). Then:

  uv run scripts/live.py            # open http://localhost:8000

Reads the screen's video buffer the display is showing, crops the picture
(568x480 at the top left of a 1024x768 Y Cb Y Cr buffer), and serves it
as a motion JPEG stream.
"""
import argparse
import io
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np
from PIL import Image

sys.path.insert(0, __import__('os').path.dirname(__file__))
import ptp  # noqa: E402
from yuv2png import convert  # noqa: E402

BUFFERS = (0xBD742B00, 0xBD8C2B00, 0xBD5C2B00)  # table at 0x7e932b84
INDEX = 0x605B5054                               # buffer on screen
STRIDE = 1024 * 2
WIDTH, HEIGHT = 568, 480


class Frames:
    def __init__(self):
        self.cam = ptp.Camera()
        self.cam.open()
        ptp.install_helpers(self.cam)
        self.count, self.since = 0, time.time()

    def jpeg(self):
        index = ptp.read32(self.cam, INDEX)
        address = BUFFERS[index % 3]
        code, _, raw = self.cam.transact(ptp.PEEK, (address, STRIDE * HEIGHT), timeout=5000)
        if code != ptp.OK:
            raise RuntimeError(f'peek failed: {code:#06x}')
        rgb = convert(raw, 1024)[:, :WIDTH]
        out = io.BytesIO()
        Image.fromarray(rgb).save(out, 'JPEG', quality=90)
        self.count += 1
        if time.time() - self.since >= 5:
            print(f'{self.count / (time.time() - self.since):.1f} frames per second')
            self.count, self.since = 0, time.time()
        return out.getvalue()


PAGE = b'<html><body style="margin:0;background:#111"><img src="/stream" style="width:100%"></body></html>'


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', type=int, default=8000)
    args = p.parse_args()
    frames = Frames()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            if self.path != '/stream':
                self.send_response(200)
                self.send_header('Content-Type', 'text/html')
                self.end_headers()
                self.wfile.write(PAGE)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
            self.end_headers()
            try:
                while True:
                    jpg = frames.jpeg()
                    self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + jpg + b'\r\n')
            except (BrokenPipeError, ConnectionResetError):
                pass

    print(f'open http://localhost:{args.port}')
    HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
