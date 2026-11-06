# PTP command 0x9484 "peek": send `length` bytes starting at `address`
# back to the computer.
#
#   request:  param 1 = address, param 2 = length (even)
#   response: 0x2001 (OK), no parameters
#
# Called by the USB command dispatcher with a0 = request, a1 = response,
# like the stock 0x9801 handler at 0x7f0d6221. Placed over the `sdk api
# changeOutLine` debug command handler, which only the serial console reaches.

        .extern tpc_send_data           # 0x7f0d9c37: a0 = pointer, d0 = chunk, d1 = total

        .am33_2
        .text
        .global peek
peek:
        movm    [d2,d3,a2,a3],(sp)
        add     -20,sp
        mov     a1,(12,sp)              # keep the response pointer
        mov     (16,a0),d2              # param 1: address
        mov     (20,a0),d3              # param 2: length
        mov     d2,a0
        mov     d3,d0
        mov     d3,d1
        call    tpc_send_data,[d2,d3,a2,a3],24
        mov     (12,sp),a0
        mov     0x2001,d0               # PTP OK
        movhu   d0,(a0)
        clr     d0
        mov     d0,(12,a0)              # no response parameters
        ret     [d2,d3,a2,a3],36
