"""Show the camera's live view in a browser, over USB.

Needs the usb-tools firmware and the camera in shooting mode with USB
connected (`uv run scripts/ptp.py shoot`). Then:

  uv run scripts/live.py            # open http://localhost:8000
  uv run scripts/live.py --movie    # 1080p, while the camera records a movie

With --movie, it reads the newest frame from the movie recorder's frame
ring instead: 1920x1080 NV12, processed by the camera, about 3 MB each.

Reads the screen's video buffer the display is showing, crops the picture
from the top left of the 1024x768 Y Cb Y Cr buffer, and serves it as a
motion JPEG stream. The picture is 568x480 on the rear screen and 800x600
on the viewfinder (`ptp.py output evf`); in movie mode it's 16:9 with a dark
band below, which is trimmed.
"""
import argparse
import io
import signal
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

def picture_size(y):
    """Width and height of the picture in a 1024x768 luma plane."""
    # Outside the picture the buffer is either never written (0xff) or a
    # flat dark band. Picture rows and columns vary.
    # The never-written area is mostly 0xff with scattered noise; the band
    # is flat. The picture ends at the last row that is neither. Heights
    # are snapped to the known modes, since dark scenes have flat rows too.
    width = 800 if (y[:400, 640:800] != 255).mean() > 0.5 else 568
    part = y[:, :width]
    picture = (part.std(1) > 2) & ((part == 255).mean(1) < 0.5)
    last = int(np.nonzero(picture)[0].max()) + 1
    heights = (450, 600) if width == 800 else (320, 480)
    return width, min(heights, key=lambda h: abs(h - last))


class Frames:
    def __init__(self):
        self.cam = ptp.Camera()
        self.cam.open()
        ptp.install_helpers(self.cam)
        self.count, self.since = 0, time.time()

    def jpeg(self):
        out = io.BytesIO()
        self.image().save(out, 'JPEG', quality=90)
        self.count += 1
        if time.time() - self.since >= 5:
            print(f'{self.count / (time.time() - self.since):.1f} frames per second')
            self.count, self.since = 0, time.time()
        return out.getvalue()


class ScreenFrames(Frames):
    """The live view picture in the screen buffer the display is showing."""

    size = None

    def image(self):
        index = ptp.read32(self.cam, INDEX)
        address = BUFFERS[index % 3]
        if self.size is None:
            raw = self.cam.transact(ptp.PEEK, (address, STRIDE * 768), timeout=5000)[2]
            self.size = picture_size(np.frombuffer(raw, np.uint8).reshape(768, 2048)[:, 0::2].astype(np.float32))
            print('picture: %dx%d' % self.size)
        width, height = self.size
        code, _, raw = self.cam.transact(ptp.PEEK, (address, STRIDE * height), timeout=5000)
        if code != ptp.OK:
            raise RuntimeError(f'peek failed: {code:#06x}')
        return Image.fromarray(convert(raw, 1024)[:, :width])


# The movie recorder's frame ring: 32 entries of 24 bytes, each
# {Y address, Y stride, CbCr address, CbCr stride, timestamp (90 kHz),
# frame number}. Frames are NV12, 1920x1088 in memory, 1080 rows used.
RING, RING_ENTRIES = 0xA07870B8, 32
MOVIE_W, MOVIE_H = 1920, 1080


class MovieFrames(Frames):
    """The newest 1080p frame from the movie recorder (only while recording)."""

    def image(self):
        ring = np.frombuffer(self.cam.transact(ptp.PEEK, (RING, RING_ENTRIES * 24))[2], '<u4').reshape(-1, 6)
        y_addr, y_stride, c_addr, _, _, number = ring[np.argmax(ring[:, 5])]
        if not number or y_stride != MOVIE_W:
            raise RuntimeError('no movie frames: is the camera recording?')
        y = self.cam.transact(ptp.PEEK, (int(y_addr), MOVIE_W * MOVIE_H), timeout=5000)[2]
        c = self.cam.transact(ptp.PEEK, (int(c_addr), MOVIE_W * MOVIE_H // 2), timeout=5000)[2]
        cbcr = np.frombuffer(c, np.uint8).reshape(MOVIE_H // 2, MOVIE_W // 2, 2)
        size = (MOVIE_W, MOVIE_H)
        planes = [Image.frombuffer('L', size, y, 'raw', 'L', 0, 1)]
        planes += [Image.fromarray(cbcr[..., i]).resize(size) for i in (0, 1)]
        return Image.merge('YCbCr', planes)


PAGE = b'<html><body style="margin:0;background:#111"><img src="/stream" style="width:100%"></body></html>'


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', type=int, default=8000)
    p.add_argument('--movie', action='store_true', help='1080p frames while recording')
    args = p.parse_args()
    frames = MovieFrames() if args.movie else ScreenFrames()

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
            nonlocal streaming
            streaming = True
            self.send_response(200)
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
            self.end_headers()
            try:
                while not stopping:
                    jpg = frames.jpeg()
                    self.wfile.write(b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + jpg + b'\r\n')
            except (BrokenPipeError, ConnectionResetError):
                pass
            if stopping:
                finish()

    # Stopping in the middle of a USB transfer leaves the camera mid-command,
    # and the reset that clears it can drop the camera off USB while it
    # shoots. So on Ctrl-C or kill, finish the current frame, close the
    # session, then exit.
    stopping = False

    def finish():
        frames.cam.close()
        print('closed the camera session')
        sys.exit(0)

    def stop(*_):
        nonlocal stopping
        if streaming:
            stopping = True
        else:
            finish()

    streaming = False
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f'open http://localhost:{args.port}')
    HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
