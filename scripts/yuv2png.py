"""Convert a raw YCbCr 4:2:2 (Y Cb Y Cr) frame from the camera to an image.

  uv run scripts/yuv2png.py frame.yuv frame.png [--width 1024]

The height comes from the file size. Writes a PPM, then converts it with
macOS's `sips` when the output name ends in .png.
"""
import argparse
import os
import subprocess

import numpy as np


def convert(raw, width):
    px = np.frombuffer(raw, np.uint8).reshape(-1, width // 2, 4).astype(np.float32)
    y = np.stack([px[..., 0], px[..., 2]], -1).reshape(px.shape[0], width)
    cb = np.repeat(px[..., 1], 2, 1) - 128
    cr = np.repeat(px[..., 3], 2, 1) - 128
    rgb = np.stack([y + 1.402 * cr, y - 0.344 * cb - 0.714 * cr, y + 1.772 * cb], -1)
    return np.clip(rgb, 0, 255).astype(np.uint8)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('input')
    p.add_argument('output')
    p.add_argument('--width', type=int, default=1024)
    a = p.parse_args()
    rgb = convert(open(a.input, 'rb').read(), a.width)
    ppm = a.output[:-4] + '.ppm' if a.output.endswith('.png') else a.output
    with open(ppm, 'wb') as f:
        f.write(f'P6 {rgb.shape[1]} {rgb.shape[0]} 255\n'.encode() + rgb.tobytes())
    if ppm != a.output:
        subprocess.run(['sips', '-s', 'format', 'png', ppm, '--out', a.output], check=True, capture_output=True)
        os.remove(ppm)
    print(f'wrote {a.output} ({rgb.shape[1]}x{rgb.shape[0]})')


if __name__ == '__main__':
    main()
