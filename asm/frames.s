# A list of finished video frames, so Mark One copies each frame exactly
# instead of guessing where it ends in the H.264 ring.
#
# The movie recorder's table of frame descriptors (0x607e5180) is written
# through the CPU cache, so over USB (which reads RAM directly) it shows up
# late, about half a second, as each cache line happens to be written back.
# This hooks the Video Encode plug-in's event handler (fn_7e5304c6) where
# it records a finished frame's offset and byte count in the frame's
# sample (`call 0x7e5277ea,[],0` at 0x7e5307b9, a leaf that stores d0 at
# +96, d1 at +100 and 1 at +104, then returns 0). It runs once per video
# frame, in the plug-in's task, right after the hardware encoder reports
# the size. The stub does the same stores, then, in webcam mode only
# (connection type 7), adds the frame to a ring that it writes through the
# uncached mirror (+0x40000000), so it reaches RAM at once.
#
#   0x7eaaac00  u32 count: frames added so far
#   0x7eaaac10  64 entries of 16 bytes, entry = count % 64:
#               {u32 address, u32 bytes, u32 timestamp (90 kHz), u32 number}
#               number (the count when it was added) is written last, so an
#               entry whose number isn't the one expected is unfinished or
#               from an earlier lap.
#
# At the hook a0 is the sample, d0 the frame's offset in the sample's
# buffer and d1 its byte count. The buffer address is at +88 (already in
# the uncached mirror, 0xa52b...), the timestamp at +24. After the hook the
# handler reloads a0, a1 and a2 (and its ret restores a2), so the stub uses
# d0, d1, a0, a1 and a2.
#
# Placed over console-only `sdk api` commands (getDisplayDeviceState from
# 0x7eaaab8e and the ones after it, to 0x7eaab024), which only the serial
# console's command table at 0x7ecda9f8 points to.
#
# Build:
#   T=toolchain/install/bin
#   $T/mn10300-elf-as -o asm/frames.o asm/frames.s
#   $T/mn10300-elf-ld -Ttext=0x7eaaab8e -e frames --defsym frames_back=0x7e5307c0 \
#     -o asm/frames.elf asm/frames.o
#   $T/mn10300-elf-objcopy -O binary asm/frames.elf asm/frames.bin
# The hook is `jmp frames` plus two nops at 0x7e5307b9; scripts/build.py
# writes it, and zeroes the count and the entries.

        .set    connection, 0x605f0d14  # 7 in webcam mode
        .set    webcam, 7
        .set    count, 0xbeaaac00       # uncached mirror of 0x7eaaac00
        .set    entries, 0xbeaaac10

        .extern frames_back             # 0x7e5307c0

        .am33_2
        .text
        .global frames

frames:
        mov     d0,(96,a0)              # what 0x7e5277ea does
        mov     d1,(100,a0)
        mov     1,d0
        mov     d0,(104,a0)
        mov     (connection),d0
        cmp     webcam,d0
        bne     1f
        mov     (count),d0
        mov     d0,a1                   # the frame's number
        and     63,d0
        asl     4,d0
        mov     entries,a2
        add     d0,a2
        mov     (88,a0),d0              # buffer
        mov     (96,a0),d1              # + offset
        add     d1,d0
        mov     d0,(a2)
        mov     (100,a0),d0
        mov     d0,(4,a2)
        mov     (24,a0),d0
        mov     d0,(8,a2)
        mov     a1,(12,a2)              # number last: the entry is complete
        inc     a1
        mov     a1,(count)
1:      clr     d0                      # 0x7e5277ea's result
        jmp     frames_back
