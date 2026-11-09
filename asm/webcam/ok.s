# The USB prompt's OK button for screen 0, rewritten in place
# (0x7eec7101-0x7eec7125). d0 = cursor. Storage, MTP, Webcam and Print send
# GUI params 15, 16, 20 and 17 to checkEndUsbSelect through 0x7eeb2c19;
# Exit goes to the stock exit path at 0x7eec7126.

        .am33_2
        .text
        .global ok
ok:
        exthu   d0
        cmp     4,d0
        beq     exit_path
        mov     params,a0
        add     d0,a0
        movbu   (a0),d1
        mov     17,d0
        jmp     send
params:
        .byte   15, 16, 20, 17
