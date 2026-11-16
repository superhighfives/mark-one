# Shows one of the GUI's warnings, for trying out a message after
# unplugging (NOTES.md, "A message after unplugging"). d0 = warning index:
# 0x11 is "One Moment", 0x24 "Remove USB Cable", 0 clears.
#
# setDbWarningInfo (0x7edf38fc) takes a0 = the GUI's common object
# (0x7edf3876 returns it), d0 = index and d1 = 1, as the USB prompt's own
# call at 0x7eeae6e2 does. It has no prologue of its own, so `run` can't
# call it directly: this sets up the frame.
#
# Loaded at run time, in the free end of the console-only `sdk api` dump
# after asm/nocard.s (0x7eaafa70-0x7eaafbb3).
#
# Build:
#   T=toolchain/install/bin
#   $T/mn10300-elf-as -o asm/wait.o asm/wait.s
#   $T/mn10300-elf-ld -Ttext=0x7eaafa70 --defsym gui_common=0x7edf3876 \
#     --defsym set_warning=0x7edf38fc -e wait -o asm/wait.elf asm/wait.o
#   $T/mn10300-elf-objcopy -O binary asm/wait.elf asm/wait.bin
# Try:
#   uv run scripts/ptp.py poke 0x7eaafa70 asm/wait.bin
#   uv run scripts/ptp.py run 0x7eaafa70 0x11

        .extern gui_common              # 0x7edf3876: a0 = CCommon
        .extern set_warning             # 0x7edf38fc: setDbWarningInfo

        .am33_2
        .text
        .global wait

wait:
        movm    [d2],(sp)
        add     -8,sp
        mov     d0,d2
        call    gui_common,[],4
        mov     d2,d0
        mov     1,d1
        call    set_warning,[d2,d3,a2,a3],16
        ret     [d2],12
