"""For each code address given (or each word of a table), print the first string the function references."""
import sys, struct, bisect
BASE = 0x7E421020
b = open('unpacked/main.bin', 'rb').read()
addrs, notes = [], []
for ln in open('disasm/main.s'):
    if len(ln) > 10 and ln[8] == ':' and ln[:8] != 'fn_' :
        try: a = int(ln[:8], 16)
        except ValueError: continue
        addrs.append(a); notes.append(ln.split('"')[1] if '"' in ln else None)
def first_str(a, span=40):
    i = bisect.bisect_left(addrs, a)
    for k in range(i, min(i + span, len(addrs))):
        if notes[k]: return notes[k]
start, count = int(sys.argv[1], 16), int(sys.argv[2])
for k in range(count):
    a = start + 4 * k
    w = struct.unpack_from('<I', b, a - BASE)[0]
    print(f"{a:#x} +{4*k:4d} {w:#010x} {first_str(w) if BASE <= w < BASE + len(b) else ''}")
