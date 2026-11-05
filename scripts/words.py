"""Dump 32-bit words of main.bin at runtime addresses; resolve pointers to strings."""
import sys, struct
BASE = 0x7E421020
b = open(sys.argv[1], 'rb').read()
start, n = int(sys.argv[2], 16), int(sys.argv[3])
def s_at(a):
    o = a - BASE
    if 0 <= o < len(b):
        e = b.find(b'\x00', o, o + 80)
        t = b[o:e]
        if e > o + 2 and all(32 <= c < 127 for c in t): return t.decode()
for k in range(n):
    a = start + 4 * k
    w = struct.unpack_from('<I', b, a - BASE)[0]
    print(f"{a:#010x}: {w:#010x} {s_at(w) or ''}")
