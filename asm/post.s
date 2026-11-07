# Posts an event to the mode manager, as if it came from the camera's own
# hardware or tasks. Run with `ptp.py run` (0x9486):
#
#   d0 = event         for example 0x01000022, movie button pressed
#   a0 = object        the PC mode object (*0x605f0d3c); method +4 sends a
#                      20-byte message to the mode manager's queue
#
# Placed after the release stub, over the usage text printing of the
# console's `sdk api ctrlRelease` command.

        .am33_2
        .text
        .global post
post:
        movm    [d2,a2],(sp)
        add     -32,sp
        clr     d1
        mov     d0,(8,sp)               # message: event, then zeros
        mov     d1,(12,sp)
        mov     d1,(16,sp)
        mov     d1,(20,sp)
        mov     d1,(24,sp)
        mov     sp,a1
        add     8,a1
        mov     (a0),a2
        mov     (4,a2),a2               # vtable slot 4: send to the queue
        calls   (a2)
        ret     [d2,a2],40
