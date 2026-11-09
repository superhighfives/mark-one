# The Custom menu USB Mode setting (118) to connection type, rewritten in
# place (0x7edd54ff-0x7edd5534) to add Webcam: Auto (255) -> 0, which asks;
# Storage (0) -> 1, Print (2) -> 4, 3 -> 3, MTP (4, 5) -> 2, Webcam (7) -> 7,
# anything else -> 1. d0 = the setting; continues at 0x7edd5535 with the
# type in d1 and stored at 0x605f0d14.

        .am33_2
        .text
        .global mode
mode:
        clr     d1
        cmp     255,d0
        beq     store
        mov     1,d1
        cmp     7,d0
        bhi     store
        mov     types,a0
        add     d0,a0
        movbu   (a0),d1
store:
        mov     d1,(0x605f0d14)
        bra     resume
types:
        .byte   1, 1, 4, 3, 2, 2, 1, 7
