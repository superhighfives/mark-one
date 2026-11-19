# Counts the camera's key events, so Mark One can tell when someone is
# using the camera's own buttons and dials, and leave its screen on.
#
# The key task sends every event (presses, releases, held keys, the dials
# and the shutter button, locked or not) through 0x7e9df69d, which starts
# with `call 0x7e751c42,[d2,d3,a2,a3],36`. Mark One points that call here
# instead, by changing only its 32-bit displacement, which sits in one
# 16-byte cache line (0x7e9df6a0), so the CPU sees either the old call or
# the new. The call has already saved d2 and a2 and set up the frame, so
# the stub can use them, adds one to the count and jumps on to 0x7e751c42
# with the event untouched in d0, d1, a0 and a1.
#
# Other events come through here too, with nobody touching the camera
# (2026-11-18/19; what sends them isn't known). Once Mark One has used the
# camera, 0x04030020 comes about 4 times a second; 0x0301xxxx, 0x0407xxxx
# and 0x040dxxxx come now and then. Counted, they kept the screen on. The
# events a person makes are all 0x02xxxxxx: press 0x0200, release 0x0201,
# held 0x0202 (the rear dial sends 0x02021901 a click), so only those are
# counted, and the rest go to a count of their own.
#
# The counts go through the uncached view of RAM, so the computer can read
# them with a plain peek:
#
#   0xbeab04a0  count of key events so far
#   0xbeab04e4  count of other events, which aren't in the first
#   0xbeab04e8  the last counted event (d0)
#   0xbeab04ec  its parameter (d1)
#
# Placed over the console's `sdk api ctrlRelease` usage text code
# (0x7eab02f5-0x7eab04ef), after asm/trace.s's ring. The words from
# 0xbeab04e4 sit at the end of that space, after the code.
#
# Build:
#   T=toolchain/install/bin
#   $T/mn10300-elf-as -o asm/keys.o asm/keys.s
#   $T/mn10300-elf-ld -Ttext=0x7eab04a4 --defsym key_track=0x7e751c42 \
#     -e keys -o asm/keys.elf asm/keys.o
#   $T/mn10300-elf-objcopy -O binary asm/keys.elf asm/keys.bin

        .am33_2
        .text
        .global keys

keys:                                   # from the call at 0x7e9df6a0
        mov     0xbeab04a0,a2
        mov     d0,d2
        lsr     24,d2
        cmp     0x02,d2
        beq     count
        mov     (0x44,a2),d2            # 0xbeab04e4
        add     1,d2
        mov     d2,(0x44,a2)
        jmp     key_track
count:
        mov     (a2),d2
        add     1,d2
        mov     d2,(a2)
        mov     d0,(0x48,a2)            # 0xbeab04e8
        mov     d1,(0x4c,a2)            # 0xbeab04ec
        jmp     key_track
