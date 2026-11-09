# The USB prompt's list (screen 0 of the builder at 0x7eec6dab), rewritten
# in place over the stock code for four items (0x7eec6dfb-0x7eec6e75) to
# show five: Storage, MTP, Webcam, Print, Exit. Items are 40-byte records
# from sp+74: a state byte (2 for the selected item, 1 for the rest), 0 at
# +1, 2 at +7 and the string ID at +8. d3 = sp+60, the screen's data.
# The cursor wraps at the count in the halfword table at 0x602bceb0, one
# entry per screen, so set screen 0's entry too.

        .am33_2
        .text
        .global prompt
prompt:
        mov     d2,d0
        call    set_screen,[],0
        mov     1507,d0                 # title: "USB"
        movhu   d0,(60,sp)
        clr     d0
        movbu   d0,(62,sp)
        movbu   d0,(63,sp)
        mov     5,d1
        movhu   d1,(66,sp)
        movhu   d0,(68,sp)
        movhu   d1,(70,sp)
        movhu   d1,(0x602bceb0)
        mov     14,a1
        add     d3,a1
        mov     names,a0
        mov     2,d0
item:
        movbu   d0,(a1)
        clr     d1
        movbu   d1,(1,a1)
        mov     2,d1
        movbu   d1,(7,a1)
        movhu   (a0),d1
        movhu   d1,(8,a1)
        add     2,a0
        add     40,a1
        mov     1,d0
        cmp     names_end,a0
        bne     item
        jmp     done
names:
        .hword  266, 1503, 1021, 209, 835   # Storage, MTP, Webcam, Print, Exit
names_end:
