# Three PTP commands for poking at the camera over USB, placed over the
# `sdk api changeOutLine` debug command handler (0x7eaaaae3, 171 bytes),
# which only the serial console reaches.
#
#   0x9484 peek  param 1 = address, param 2 = length
#                data: camera to computer, `length` bytes from `address`
#   0x9485 poke  param 1 = address
#                data: computer to camera, written to `address`
#   0x9486 run   param 1 = function, params 2-5 = d0, d1, a0, a1
#                response params: d0, a0 after the call
#
# USB transfers only reach uncached addresses: the driver refuses odd
# addresses and anything with bit 30 set (0x4xxxxxxx-0x7xxxxxxx, the
# cached view of RAM). Add 0x40000000 to use the uncached mirror. peek
# checks this and answers 0x201d (invalid parameter) instead of hanging;
# poke can't, because the computer has already sent the data, so the
# computer must check.
#
# `run` calls the target with `calls`, so the target must set up its own
# frame (start with movm/add and end with ret), like a command handler.
#
# Handlers are called by the USB command dispatcher with a0 = request
# (parameters from +16) and a1 = response (code at +0, parameter count
# at +12, parameters from +16).

        .extern tpc_send_data           # 0x7f0d9c37: a0 = pointer, d0 = chunk, d1 = total
        .extern tpc_recv_start          # 0x7f0d9cfa: returns d0 = data length
        .extern tpc_recv_data           # 0x7f0d9d70: a0 = pointer, d0 = length; d0 = 1 on success

        .am33_2
        .text
        .global peek, poke, run

peek:
        movm    [d2,d3,a2,a3],(sp)
        add     -20,sp
        mov     a1,(12,sp)              # keep the response pointer
        mov     (16,a0),d2              # address
        mov     (20,a0),d3              # length
        mov     0x201d,a3               # invalid parameter, until sent
        mov     0x40000001,d0           # odd or cached: the driver refuses it
        and     d2,d0
        bne     reply
        cmp     0,d3
        beq     reply
        mov     d2,a0
        mov     d3,d0
        mov     d3,d1
        call    tpc_send_data,[d2,d3,a2,a3],24
        mov     0x2001,a3               # OK
reply:
        mov     (12,sp),a0
        mov     a3,d0
        movhu   d0,(a0)
        clr     d0
        mov     d0,(12,a0)              # no response parameters
        ret     [d2,d3,a2,a3],36

poke:
        movm    [d2,d3,a2,a3],(sp)
        add     -20,sp
        mov     a1,(12,sp)
        mov     (16,a0),d2              # address
        mov     0x2002,a3               # general error, until received
        call    tpc_recv_start,[d2,a2],16
        cmp     0,d0
        beq     reply
        mov     d2,a0                   # d0 is still the length
        call    tpc_recv_data,[d2,d3,a2],20
        cmp     1,d0
        bne     reply
        mov     0x2001,a3
        bra     reply

run:
        movm    [d2,d3,a2,a3],(sp)
        add     -20,sp
        mov     a1,(12,sp)
        mov     a0,a2
        mov     (16,a2),a3              # function
        mov     (20,a2),d0
        mov     (24,a2),d1
        mov     (32,a2),a1
        mov     (28,a2),a0
        calls   (a3)
        mov     (12,sp),a1
        mov     0x2001,d2
        movhu   d2,(a1)
        mov     2,d2
        mov     d2,(12,a1)              # two response parameters
        mov     d0,(16,a1)
        mov     a0,(20,a1)
        ret     [d2,d3,a2,a3],36
