# checkEndUsbSelect's mapping from the prompt's GUI param to a connection
# type, rewritten in place (0x7edd5bb2-0x7edd5bd0): 15 Storage -> 1,
# 16 MTP -> 2, 17 Print -> 4, 20 Webcam -> 7, anything else -> 5 (exit).
# a2 = the message; the type goes to 0x7edd5552 at 0x7edd5bd1 in d0.

        .am33_2
        .text
        .global select
select:
        mov     (4,a2),d0
        add     -15,d0
        cmp     5,d0
        bls     known
        mov     3,d0                    # types[3] is 5, exit
known:
        mov     types,a0
        add     d0,a0
        movbu   (a0),d0
        bra     set_type
types:
        .byte   1, 2, 4, 5, 5, 7
        .org    0x1f, 0xcb              # set_type is the next instruction
set_type:
