# Restarts the camera once a USB install has finished, instead of leaving
# it on OK, still running the old firmware, until the power switch moves.
#
# After an install the firmup task calls fn_7e9df2e9 ("Owariyade"), which
# waits for the power switch to change, then powers off. Only the end of an
# install calls it (0x7e753168 "api_firmup_Firmup_Client_END", 0x7e9df18d,
# 0x7e9df2e1). Mark One writes this over its start, in memory, before
# starting the install (the camera drops off USB as soon as it starts):
# the same forced restart the firmware does at boot when its second CPU
# doesn't answer (0x7e5e53e6): mask interrupts, so the watchdog stops being
# fed, and set the watchdog to 1 s. The camera restarts and loads the new
# firmware from flash. Nothing is written to flash.
#
# Tested 2026-11-10: a USB install of revision 3 showed OK, then the camera
# restarted by itself and came back at the USB prompt with revision 3 and
# none of Mark One's in-memory changes. A watchdog restart doesn't save
# settings changed since the last power-off.
#
# Build:
#   T=toolchain/install/bin
#   $T/mn10300-elf-as -o asm/restart.o asm/restart.s
#   $T/mn10300-elf-ld -Ttext=0x7e9df2e9 -e restart --defsym int_mask=0x7e4431bf \
#     --defsym wdt_time=0x40064e17 -o asm/restart.elf asm/restart.o
#   $T/mn10300-elf-objcopy -O binary asm/restart.elf asm/restart.bin
# Firmware.restartCode in mac/MarkOne/App/Firmware.swift holds the bytes.

        .am33_2
        .text
        .global restart

restart:
        mov     1,d0
        call    int_mask,[],0           # interrupts off: the watchdog isn't fed
        mov     1,d0
        call    wdt_time,[],0           # watchdog period 1 s
spin:   bra     spin
