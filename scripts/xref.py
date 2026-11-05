"""Find a string in main.bin and every place its runtime address appears (any alignment)."""
import sys, struct
BASE = 0x7E421020
b = open(sys.argv[1], 'rb').read()
for s in sys.argv[2:]:
    needle = s.encode() + b'\x00'
    i = b.find(b'\x00' + needle)
    hits = []
    while i >= 0:
        addr = BASE + i + 1
        pat = struct.pack('<I', addr)
        j = b.find(pat)
        refs = []
        while j >= 0:
            refs.append(BASE + j); j = b.find(pat, j + 1)
        hits.append((addr, refs))
        i = b.find(b'\x00' + needle, i + 1)
    for addr, refs in hits:
        print(f"{s!r} @ {addr:#010x}  refs: {' '.join(f'{r:#010x}' for r in refs) or '-'}")
    if not hits:
        print(f"{s!r} not found as whole string")
