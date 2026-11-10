# Movies in webcam mode that never touch the card: no card needed, no
# empty movie file, no time limit.
#
# Mark One reads the H.264 stream from the movie recorder's ring buffer in
# RAM, so the recorder's file work is wasted, and with no card in it fails:
# the recording limit works out to 0 from the card's free space, and the
# file number, the file and its folder entry need the card. Each hook below
# replaces one instruction with a jump to a stub here. In webcam mode
# (connection type 7 at 0x605f0d14) the stub fakes what that step would
# report with a card in and nothing written, which is what Mark One's
# runtime 'card writes' patches already produce. Otherwise it runs the
# replaced instruction and carries on, so normal movies are unchanged.
#
# Every faked step reports success. An error from the QuickTime file task
# makes the muxer's task exit, which hangs the recorder (see NOTES.md,
# "Recording time limit"). The file task's requester also waits until the
# busy flag at 0xa0785940 clears, so the file stubs clear it
# (file_done) as the real handlers do.
#
#   S1  0x7e7bc1bd  aud_wait: after getting the recorder state, set the
#                   frame limits at +32/+36/+40 to 32767 s
#   S2  0x7e7bca0d  skip the TIME_LIMIT check
#   S3  0x7e7a7c5f  muxer ulMaxRecTime: 2 hours instead of 30 minutes
#   S4  0x7e7c0429  MOV_FILE: skip opening and writing the file
#   S5  0x7e7a710c  QT_FILE open: report success with no file
#   S6  0x7e7a717c  QT_FILE seek: track the position an empty file would have
#   S7  0x7e7a7197  QT_FILE get position: report it
#   S8  0x7e7a7144  QT_FILE read: end of file, as an empty file gives
#   S9  0x7e7a797d  record_start: don't reserve a file number on the card
#                   (IMDF 50); fill in what the reservation would, from
#                   stand-ins
#   S10 0x7e7bc3d8  record_end: skip naming and closing the file (IMDF 51)
#   S11 0x7e7bc3d1  record cancel: skip IMDF 56
#   S12 0x7e7bfff0  QT_FILE remove: skip deleting the file
#   S13 0x7eb718e3  the shooting app's movie start check: report the
#                   card as ready (0xf000), so REC works with no card
#
# The stubs at call sites run the same call from here, so the callee sees
# the same arguments and stack. They use only d0, d1, a0 and a1 where
# those are free, and borrow d2 on the stack for the webcam test where
# they aren't (movm doesn't change the flags).
#
# Placed over the console-only `sdk api` EV_* dump, after asm/refusal.s.
#
# Build:
#   T=toolchain/install/bin
#   $T/mn10300-elf-as -o asm/nocard.o asm/nocard.s
#   $T/mn10300-elf-ld -Ttext=0x7eaaf760 -e nocard $(sed -n 's/^ *\.extern \([a-z0-9_]*\) *# \(0x[0-9a-f]*\).*/--defsym \1=\2/p' asm/nocard.s) \
#     -o asm/nocard.elf asm/nocard.o
#   $T/mn10300-elf-objcopy -O binary asm/nocard.elf asm/nocard.bin
# The hooks are 5-byte `jmp` instructions (plus nops for longer ones) to
# the s1-s12 labels; scripts/build.py writes them.

        .set    connection, 0x605f0d14  # 7 in webcam mode
        .set    webcam, 7
        .set    qt_file, 0x605b52d8     # QT_FILE's FILE*; 0 = no file

        .extern file_done               # 0x7e7a62d9, clears the file task's busy flag
        .extern recorder_state          # 0x7e7bb89a
        .extern s1_back                 # 0x7e7bc1c2
        .extern s2_back                 # 0x7e7bca12
        .extern time_limit_check        # 0x7e7bc076
        .extern s3_back                 # 0x7e7a7c65
        .extern s4_back                 # 0x7e7c042e
        .extern mov_write               # 0x7e7c044f
        .extern s5_back                 # 0x7e7a7111
        .extern qt_open                 # 0x7e7a7240
        .extern s6_back                 # 0x7e7a7181
        .extern qt_seek                 # 0x7e7a7652
        .extern s7_back                 # 0x7e7a719c
        .extern qt_tell                 # 0x7e7a7811
        .extern s8_back                 # 0x7e7a7149
        .extern qt_read                 # 0x7e7a7729
        .extern s9_back                 # 0x7e7a7982
        .extern imdf_send               # 0x7e7ac1eb
        .extern s10_back                # 0x7e7bc3dd
        .extern record_end              # 0x7e7c0531
        .extern s11_back                # 0x7e7bc3d6
        .extern record_cancel           # 0x7e7c05d3
        .extern s12_back                # 0x7e7bfff7
        .extern qt_remove               # 0x7e7a71fe
        .extern media_state             # 0x7ea7fcd1
        .extern s13_back                # 0x7eb718ea

        .am33_2
        .text
        .global nocard
        .global s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13

nocard:
position:       .long 0                 # the position an empty file would have

# Branches to \stock unless the camera is in webcam mode. Borrows d2.
        .macro  unless_webcam stock
        movm    [d2],(sp)
        mov     (connection),d2
        cmp     webcam,d2
        movm    (sp),[d2]
        bne     \stock
        .endm

# S1: `call recorder_state,[],4` at 0x7e7bc1bd, then aud_wait reads the
# limit at (40,a0) and stops if it's 0. d1 is loaded next, so it's free.
s1:
        call    recorder_state,[],4
        mov     (connection),d1
        cmp     webcam,d1
        bne     1f
        mov     983010,d1               # 32767 s at 30 frames per second
        mov     d1,(32,a0)
        mov     d1,(36,a0)
        mov     d1,(40,a0)
1:      jmp     s1_back

# S2: `call time_limit_check,[d2,a2,a3],16` at 0x7e7bca0d.
s2:
        unless_webcam 1f
        jmp     s2_back
1:      call    time_limit_check,[d2,a2,a3],16
        jmp     s2_back

# S3: `mov d0,(0x6072fcd4)` at 0x7e7a7c5f stores the muxer's maximum time.
s3:
        unless_webcam 1f
        mov     7200000,d0              # 2 hours, the value SD movies get
1:      mov     d0,(0x6072fcd4)
        jmp     s3_back

# S4: `call mov_write,[d2,d3,a2],16` at 0x7e7c0429 opens the movie file if
# it isn't, then writes. 0 is success.
s4:
        unless_webcam 1f
        clr     d0
        jmp     s4_back
1:      call    mov_write,[d2,d3,a2],16
        jmp     s4_back

# S5: `call qt_open,[d2,d3,a2,a3],32` at 0x7e7a710c (a0 = message). No
# file: QT_FILE's writes and closes skip themselves while its FILE* is 0.
s5:
        unless_webcam 1f
        clr     d0
        mov     d0,(qt_file)
        mov     d0,(position)
        call    file_done,[],0
        clr     d0
        jmp     s5_back
1:      call    qt_open,[d2,d3,a2,a3],32
        jmp     s5_back

# S6: `call qt_seek,[d2,d3,a2,a3],28` at 0x7e7a717c. (12,a0) points to
# {u32 offset, u16 direction (1 = back), u16 origin (1 = current)}. With
# nothing written, the start and the end of the file are both 0.
s6:
        unless_webcam 3f
        mov     (12,a0),a1
        mov     (a1),d0
        movhu   (4,a1),d1
        cmp     1,d1
        bne     1f
        mov     d0,d1                   # back: negate the offset
        clr     d0
        sub     d1,d0
1:      movhu   (6,a1),d1
        cmp     1,d1
        bne     2f
        mov     (position),d1
        add     d1,d0
2:      mov     d0,(position)
        call    file_done,[],0
        clr     d0
        jmp     s6_back
3:      call    qt_seek,[d2,d3,a2,a3],28
        jmp     s6_back

# S7: `call qt_tell,[d2,a2],16` at 0x7e7a7197. The position goes to the
# u32 that (12,a0) points to.
s7:
        unless_webcam 1f
        mov     (12,a0),a1
        mov     (position),d0
        mov     d0,(a1)
        call    file_done,[],0
        clr     d0
        jmp     s7_back
1:      call    qt_tell,[d2,a2],16
        jmp     s7_back

# S8: `call qt_read,[d2,d3,a2,a3],32` at 0x7e7a7144. (12,a0) points to a
# request whose (8,..) gets the count read and (20,..) the status. An
# empty file reads 0 bytes, status 2 (end of file), which it returns.
s8:
        unless_webcam 1f
        mov     (12,a0),a1
        mov     (8,a1),a0
        clr     d0
        mov     d0,(a0)
        mov     (20,a1),a0
        mov     2,d0
        mov     d0,(a0)
        call    file_done,[],0
        mov     2,d0
        jmp     s8_back
1:      call    qt_read,[d2,d3,a2,a3],32
        jmp     s8_back

# S9: `call imdf_send,[],4` at 0x7e7a797d, in IMDF 50 (0x7e7a792e), which
# record_start calls to reserve the movie's file number on the card. a0
# is the request, at +156 in the recorder's state. The send has the file
# system fill in the recorder's +172/+176 and point +180 at the movie's
# folder entry, and write the movie's path to 0x605b52dc; the muxer's
# start reads them, and crashes on a null +180. Fill them in from
# stand-ins, copied from a real reservation (2026-11-09), instead.
# 0 is success.
s9:
        unless_webcam 2f
        mov     fake_file,d0
        mov     d0,(24,a0)              # +180: the movie's folder entry
        mov     0x40210000,d0
        mov     d0,(16,a0)              # +172
        mov     d0,(20,a0)              # +176
        mov     fake_path,a0            # copy the path, word by word
        mov     0x605b52dc,a1
        mov     8,d1
1:      mov     (a0),d0
        mov     d0,(a1)
        inc4    a0
        inc4    a1
        add     -1,d1
        bne     1b
        clr     d0
        jmp     s9_back
2:      call    imdf_send,[],4
        jmp     s9_back

        .align  2
# A movie file entry: two words, the folder entry, "P1010001" "MOV".
fake_file:
        .long   0, 0, fake_folder
        .ascii  "P1010001MOV"
        .byte   0
        .long   0, 0, 0, 0x00610000, 0, 0, 0, 0x40210000, 0x40210000, 0
        .long   0, 0, 0, 0, 0, 0, 0, 0, 0
        .long   0x00010064, 0x20202020
        .long   0, 0, 0, 0, 0, 0
# Its folder: "100OLYMP", number 100.
fake_folder:
        .long   0, 0
        .ascii  "100OLYMP   "
        .byte   0, 0, 0, 0x64, 0, 0, 0, 0x60, 0, 0x1c, 0x1e, 0x02, 0
        .long   0, 0, 0, 0x2b04
fake_path:
        .ascii  "C:\\DCIM\\100OLYMP\\P1010001.MOV"
        .byte   0, 0, 0

# S10: `call record_end,[a2,a3],12` at 0x7e7bc3d8 opens, registers and
# closes the file and finishes its number (IMDF 51). Nothing uses d0 after.
s10:
        unless_webcam 1f
        jmp     s10_back
1:      call    record_end,[a2,a3],12
        jmp     s10_back

# S11: `call record_cancel,[],4` at 0x7e7bc3d1 (IMDF 56).
s11:
        unless_webcam 1f
        jmp     s11_back
1:      call    record_cancel,[],4
        jmp     s11_back

# S12: `call qt_remove,[d2,d3],12` (7 bytes) at 0x7e7bfff0, the start of a
# function that returns its result.
s12:
        unless_webcam 1f
        clr     d0
        jmp     s12_back
1:      call    qt_remove,[d2,d3],12
        jmp     s12_back

# S13: `call media_state,[d2,d3],8` (7 bytes) at 0x7eb718e3, in the shooting
# app's movie start check (movie_record_start, 0x7eb7185e). With d0 = 4 it
# returns the card's state for movies: 0xf000 when a card is ready, 0x1001
# with none, which refuses REC silently (line 7910). In webcam mode report
# ready to this check only; nothing else sees it.
s13:
        call    media_state,[d2,d3],8
        unless_webcam 1f
        mov     0xf000,d0
1:      jmp     s13_back
