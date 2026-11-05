"""Annotate objdump output: string pointers in immediates, and call-target labels.

Usage: annotate.py main.bin main.raw.s main.s
"""
import sys, re
BASE = 0x7E421020
b = open(sys.argv[1], 'rb').read()
END = BASE + len(b)

def s_at(a):
    o = a - BASE
    if 0 <= o < len(b) and (o == 0 or b[o - 1] == 0):
        e = b.find(b'\x00', o, o + 120)
        t = b[o:e]
        if e - o >= 4 and all(32 <= c < 127 or c in (9, 10) for c in t):
            return t.decode().replace('\n', '\\n')

line_re = re.compile(r'^([0-9a-f]{8}):\t([0-9a-f ]+?)\s*\t(.*)$')
cont_re = re.compile(r'^([0-9a-f]{8}):\t([0-9a-f ]+?)\s*$')
num_re = re.compile(r'(?<![\w(])(-?\d{6,})(?=[,\s]|$)')
call_re = re.compile(r'\bcall\s+0x([0-9a-f]{8})')

rows, targets = [], set()
for ln in open(sys.argv[2]):
    m = line_re.match(ln)
    if m:
        addr, ins = int(m.group(1), 16), m.group(3)
        c = call_re.search(ins)
        if c: targets.add(int(c.group(1), 16))
        rows.append([addr, ins])
with open(sys.argv[3], 'w') as out:
    for addr, ins in rows:
        if addr in targets:
            out.write(f"\nfn_{addr:08x}:\n")
        notes = []
        for n in num_re.findall(ins):
            v = int(n) & 0xFFFFFFFF
            if BASE <= v < END:
                s = s_at(v)
                notes.append(f'{v:#010x} "{s}"' if s else f'{v:#010x}')
            elif v >= 0x01000000:
                notes.append(f'{v:#010x}')
        out.write(f"{addr:08x}:  {ins}" + (f"   ; {' | '.join(notes)}" if notes else "") + "\n")
print("functions (call targets):", len(targets))
