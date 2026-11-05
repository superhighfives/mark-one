"""Find where 32-bit values appear in main.bin (any alignment), as runtime addresses."""
import sys, struct
BASE = 0x7E421020
b = open(sys.argv[1], 'rb').read()
for v in sys.argv[2:]:
    pat = struct.pack('<I', int(v, 16)); j = b.find(pat); out = []
    while j >= 0:
        out.append(f"{BASE+j:#010x}(prev {b[j-2:j].hex()})"); j = b.find(pat, j + 1)
    print(v, len(out), ' '.join(out[:40]))
