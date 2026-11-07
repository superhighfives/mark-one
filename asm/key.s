# Puts a key event straight onto the camera's key queue, as the key task
# does after a button press, skipping the filter (0x7e751eeb) that drops
# keys the current mode excludes. Run with `ptp.py run` (0x9486):
#
#   d0 = event         0x0200xxxx press, 0x0201xxxx release; xxxx is the
#                      key (0x000b "Cut1", the movie button by default)
#   d1 = parameter     0 for buttons
#   a0 = source        0 for buttons
#
# key_post (0x7e751c1b) sends the 12-byte message to the queue and is
# entered with `call ...,[],32`. Placed over the usage text printing of the
# console's `sdk api ctrlRelease` command, after asm/post.s.

        .am33_2
        .text
        .global key
key:
        add     -8,sp
        call    key_post,[],32
        ret     [],8
        nop                             # pads to an even length for poke
