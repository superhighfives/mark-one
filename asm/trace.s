# Records what the mode manager logs, for watching mode changes from the
# computer. The mode manager reports each step (state handlers, change
# requests, refusals such as "USB CONNECT CHECK NG!!", incoming system
# events) through two loggers, which each ask 0x7edda2cd whether logging
# is on (a0 = the message's category):
#
#   0x7edda1e3  a1 = message
#   0x7edda1f8  a1 = message, d0 = a number to print with it
#
# A jump at the start of each brings it here. The entry does what the
# jump overwrote, records the message address and number in a 32-entry
# ring and goes back to the logger. Each jump fits in one 16-byte cache
# line, so the CPU sees either the old code or the new.
#
# The ring and its count go through the uncached view of RAM, so the
# computer can read them with a plain peek:
#
#   0xbeab03dc  count of messages so far
#   0xbeab03e0  ring of {message, number}, entry = count % 32
#
# Placed over the console's `sdk api ctrlRelease` usage text code
# (0x7eab02f5-0x7eab04ef), after asm/key.s.

        .am33_2
        .text
        .global message, numbered

message:                                # from 0x7edda1e3; keeps d2
        mov     a1,a3                   # what the jump overwrote
        mov     a0,a2
        clr     d0
        call    record,[],0
        mov     a2,a0
        call    log_check,[d2],8
        jmp     message_resume

numbered:                               # from 0x7edda1f8
        mov     d0,d2                   # what the jump overwrote
        mov     a1,a3
        mov     a0,a2
        call    record,[],0
        mov     a2,a0
        call    log_check,[d2],8
        jmp     numbered_resume

record:                                 # a3 = message, d0 = number
        mov     0xbeab03dc,a0
        mov     (a0),d1
        mov     d1,a1
        inc     d1
        mov     d1,(a0)
        mov     a1,d1
        and     31,d1
        asl2    d1
        add     d1,d1                   # 8 bytes an entry
        mov     0xbeab03e0,a1
        add     d1,a1
        mov     a3,(a1)
        mov     d0,(4,a1)
        ret     [],0
