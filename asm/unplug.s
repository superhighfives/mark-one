# Leaves the camera usable when its USB cable is unplugged in webcam mode.
#
# While Mark One uses the camera, it locks most buttons (the key cancel list
# at 0x605aabd0), forces the mode dial to movie (the override at
# 0x605aedbc) and records a movie. It undoes all three when it lets go, but
# when the cable comes out first nothing does. Worse, while a movie records
# the shooting app drops the unplug event, so the camera keeps recording
# with its buttons and dial dead until the battery comes out.
#
# The system event callback (notifySystemEventCallback, 0x7edd910c,
# d1 = event, a0 = its context) starts with a jump here. For the unplug
# event (9), this first does what Mark One does when it lets go: clear the
# dial state in the override (keeping its flag half), unlock the buttons
# with resetKeyEvent and, if a movie is recording (sequence state 0x10 at
# 0x602b1ff4), press and release REC through Mark One's key stub, which
# reaches the key queue past the lock. Then, for every event, it runs the
# two instructions the jump replaced and carries on in the callback.
#
# Placed over console usage code at 0x7eaaf600, clear of what Mark One uses.
#
# Build:
#   T=toolchain/install/bin
#   $T/mn10300-elf-as -o asm/unplug.o asm/unplug.s
#   $T/mn10300-elf-ld -Ttext=0x7eaaf600 --defsym reset_keys=0x7eacb21a \
#     --defsym key_stub=0x7eab0380 --defsym callback_body=0x7edd9111 \
#     -e unplug -o asm/unplug.elf asm/unplug.o
#   $T/mn10300-elf-objcopy -O binary asm/unplug.elf asm/unplug.bin

        .extern reset_keys              # 0x7eacb21a, resetKeyEvent
        .extern key_stub                # 0x7eab0380, asm/key.s: d0 = key event
        .extern callback_body           # 0x7edd9111

        .am33_2
        .text
        .global unplug

unplug:
        cmp     9,d1
        bne     original
        add     -16,sp
        mov     a0,(0,sp)
        mov     a1,(4,sp)
        mov     d0,(8,sp)
        mov     d1,(12,sp)
        mov     (0x605aedbc),d0         # dial override: clear the dial state
        and     0xffff0000,d0
        mov     d0,(0x605aedbc)
        calls   reset_keys              # unlock the buttons
        mov     (0x602b1ff4),d0         # recording a movie?
        cmp     0x10,d0
        bne     restore
        mov     0x02001209,d0           # REC press...
        calls   key_stub
        mov     0x02011209,d0           # ...and release
        calls   key_stub
restore:
        mov     (0,sp),a0
        mov     (4,sp),a1
        mov     (8,sp),d0
        mov     (12,sp),d1
        add     16,sp
original:
        movm    [d2,d3,a2,a3],(sp)      # what the jump replaced
        add     -28,sp
        jmp     callback_body
