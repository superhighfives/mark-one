# Records why the shooting app refused a trigger, such as REC with no card.
#
# Every refusal in the shooting app's trigger checks goes through one
# logger, 0x7eb6b884 ("TRGD:%s, %d"), with the source line in d0 and a tag
# string in a1, and logs nothing unless debug output is on. Its first
# instruction, `mov (0x602b35a4),d1` (6 bytes), becomes a jump here. This
# keeps the last line and tag and counts calls, then runs the replaced
# instruction and carries on in the logger.
#
# Diagnostic only, loaded at run time. Read the results through the cache
# with read32 (see ptp.py): last line at refusal_line, tag pointer at
# refusal_tag, the line before at refusal_prev, count at refusal_count.
#
# Placed over the console-only `sdk api` EV_* dump at 0x7eaaf720.
#
# Build:
#   T=toolchain/install/bin
#   $T/mn10300-elf-as -o asm/refusal.o asm/refusal.s
#   $T/mn10300-elf-ld -Ttext=0x7eaaf720 --defsym logger_body=0x7eb6b88a \
#     -e refusal -o asm/refusal.elf asm/refusal.o
#   $T/mn10300-elf-objcopy -O binary asm/refusal.elf asm/refusal.bin

        .extern logger_body             # 0x7eb6b88a, the logger after the replaced mov

        .am33_2
        .text
        .global refusal

refusal_line:   .long 0                 # the last refusal's line
refusal_tag:    .long 0                 # and its tag
refusal_count:  .long 0
refusal_prev:   .long 0                 # the line before it

refusal:
        mov     (refusal_line),d1
        mov     d1,(refusal_prev)
        mov     d0,(refusal_line)
        mov     a1,(refusal_tag)
        mov     (refusal_count),d1
        inc     d1
        mov     d1,(refusal_count)
        mov     (0x602b35a4),d1         # the replaced instruction
        jmp     logger_body
