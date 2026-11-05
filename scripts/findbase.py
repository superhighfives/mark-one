"""Guess main.bin's runtime base: count 32-bit words that point at string starts."""
import sys, re
import numpy as np
b = open(sys.argv[1], 'rb').read()
starts = np.array([m.start() for m in re.finditer(rb'(?<=\x00)[\x20-\x7e]{6,}\x00', b)], dtype=np.int64)
is_start = np.zeros(len(b) + 1, dtype=bool); is_start[starts] = True
words = np.frombuffer(b[:len(b) // 4 * 4], dtype='<u4').astype(np.int64)
res = []
for hi in range(0x7c00, 0x9400):          # bases 0x7c000000..0x93ff0000, plus common low offsets
    for lo in (0x0000, 0x1000, 0x1020, 0x0020):
        base = (hi << 16) | lo
        off = words - base
        ok = (off >= 0) & (off < len(b))
        n = int(is_start[off[ok]].sum())
        res.append((n, base))
res.sort(reverse=True)
print("strings:", len(starts))
for n, base in res[:8]:
    print(f"{base:#010x} {n}")
