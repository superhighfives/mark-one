# Sends a key event the way the key task does for a real button press.
# The key task's send function (0x7e9df69d) updates the long press table
# (0x7e751c42), runs the filter that drops keys the current mode excludes
# (0x7e751eeb), then posts the event to the key queue. Unlike asm/key.s,
# keys the current mode excludes stay excluded. Run with `ptp.py run`
# (0x9486):
#
#   d0 = event         0x0200xxxx press, 0x0201xxxx release; xxxx is the
#                      key (0x0100 "Trg1", the shutter button half press)
#   d1 = parameter     0 for buttons
#   a0 = source        0 for buttons
#
# Placed over the usage text printing of the console's
# `sdk api cancelKeyEvent` command, just before the getSetting output word
# Mark One uses at 0x7eaaf5f0.

        .am33_2
        .text
        .global button
button:
        add     -8,sp
        call    key_task_send,[d2,d3],12
        ret     [],8
        nop                             # pads to an even length for poke
