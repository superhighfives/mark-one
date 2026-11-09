# Lets MTP connections use the firmware update commands (0x911c-0x9125),
# which the camera normally registers only for connection modes 0 and 5.
#
# MTP's command setup (0x7f0d4a5b) ends by registering one command with
# `call register,[d2,d3,a2,a3],20` and returning with `ret [],4`. Those
# two instructions become a jump here: make the original registration
# (its arguments are still in d0, d1, a0 and a1), run the block of modes 0
# and 5's setup that registers the update commands, then return for the
# setup function. That block ends with `ret [a2],8`, so it's called with
# the same frame.

        .extern register                # 0x7f0d9ab7
        .extern firmup_block            # 0x7f0d49a4

        .am33_2
        .text
        .global firmup

firmup:
        call    register,[d2,d3,a2,a3],20
        call    firmup_block,[a2],8
        ret     [],4
