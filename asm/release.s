# Calls OlyApiShootingController::ctrlRelease, the shutter and movie button
# control behind the serial console's `sdk api ctrlRelease`. Run with
# `ptp.py run` (0x9486):
#
#   d0 = releaseGo     0 auto release enabled, 1 disabled, 2 forced off
#   d1 = takePicture   1 to take a picture
#   a1 = takeMovie     1 to start or stop a movie
#   a0 = key_movie     key ID for the movie button (11, API_MOVIE_KEY)
#
# key_1st and key_2nd are fixed at their defaults (2 and 3). Returns the
# method's result in d0.
#
# Placed over the usage text printing of that console command
# (0x7eab02f2-0x7eab04f2), which only runs from the serial console.

        .extern controller              # 0x7ead145d: returns the controller in a0

        .am33_2
        .text
        .global release
release:
        movm    [d2,d3,a2,a3],(sp)
        add     -20,sp
        mov     d0,d2                   # releaseGo
        mov     d1,d3                   # takePicture
        mov     a1,a3                   # takeMovie
        mov     a0,a2                   # key_movie
        call    controller,[],4         # a0 = controller (this)
        mov     2,d0
        mov     d0,(4,sp)               # key_1st
        mov     3,d0
        mov     d0,(8,sp)               # key_2nd
        mov     a2,(12,sp)              # key_movie
        mov     (a0),a2
        mov     (256,a2),a2             # vtable slot 256: ctrlRelease
        mov     d2,d0
        mov     d3,d1
        mov     a3,a1
        calls   (a2)
        ret     [d2,d3,a2,a3],36
