# em5-webcam

Research and firmware patches for using an original Olympus OM-D E-M5 (Mark I, 2012) as a webcam on a Mac. Stock firmware refuses to shoot while an HDMI cable is plugged in, and its USB connection only transfers files, so the plan is to change that in the firmware.

Status: two candidate patches, built and checked offline but not yet tried on a camera. `hdmi-liveview` lets the camera show live view over HDMI while shooting. `usb-peek` adds a USB command that reads camera memory, the first step toward a USB webcam. Flashing modified firmware can brick a camera. Read the risks in `NOTES.md` first.

## Running it

You need [uv](https://docs.astral.sh/uv/), `curl` and `xz`. uv installs Python and the dependencies (`numpy`, and `pyusb` with a bundled libusb) for you.

Install the dependencies, then fetch and unpack the stock v2.3 firmware. The firmware is Olympus's, so it isn't in this repo; the script downloads it and checks its hash.

```sh
scripts/setup.sh
```

Build the patched firmware with any combination of patches. The script checks every byte it replaces, so it won't patch anything other than stock v2.3.

```sh
uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN patched/hdmi-liveview/E0972300.BIN hdmi-liveview
uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN patched/usb-peek/E0972300.BIN usb-peek
```

Check that repacking the unmodified firmware reproduces the original file:

```sh
uv run scripts/build.py --roundtrip fw/OLY_E_097_2300_0000_0000.BIN
```

To flash, copy the `.BIN` into a `DCOLYMP` folder on the SD card, hold OK while turning the camera on, and wait for the light. Restore by flashing the stock file the same way, or with Olympus's updater. `NOTES.md` has the full test plan.

## Talking to the camera over USB

`scripts/ptp.py` sends raw PTP commands. Set the camera's USB Mode to MTP and connect it. If macOS has already claimed the camera, run `killall ptpcamerad` first.

```sh
uv run scripts/ptp.py info                  # model, firmware and supported commands
uv run scripts/ptp.py peek 0x602adef8 4     # read camera memory (needs usb-peek)
```

## Reading the code

The camera runs Panasonic MN103 processors. To disassemble it, build GNU binutils for that target into `toolchain/`:

```sh
mkdir -p toolchain && cd toolchain
curl -sSfLO https://ftp.gnu.org/gnu/binutils/binutils-2.43.1.tar.xz
tar xf binutils-2.43.1.tar.xz && mkdir build && cd build
../binutils-2.43.1/configure --target=mn10300-elf --prefix="$PWD/../install" \
  --disable-nls --disable-werror --disable-gdb --disable-gprofng --disable-sim \
  --with-system-zlib MAKEINFO=true
make -j8 MAKEINFO=true && make install MAKEINFO=true
```

Then disassemble the main code block and label it:

```sh
mkdir -p disasm
toolchain/install/bin/mn10300-elf-objdump -D -b binary -m am33-2 \
  --adjust-vma=0x7E421020 unpacked/main.bin > disasm/main.raw.s
uv run scripts/annotate.py unpacked/main.bin disasm/main.raw.s disasm/main.s
```

`disasm/main.s` marks every string a piece of code refers to and labels each function that something calls. The other scripts help you find your way around, and all run with `uv run scripts/<name>.py`:

- `xref.py` finds a string and everything that points at it.
- `findimm.py` finds where a 32-bit value appears.
- `words.py` dumps memory as words and shows any strings they point to.
- `fnname.py` labels a table of function pointers by the first message each function logs.
- `findbase.py` works out where the main block sits in memory (`0x7E421020`).

## How it works

The firmware is a set of scrambled blocks with checksums. `olyfw.py`, from [xulfr/om-emu](https://github.com/xulfr/om-emu), descrambles them. `build.py` changes bytes in the decoded main block, scrambles it again, and fixes the checksum.

The camera's shooting mode already sends live view to the analog video port: when that cable goes in, shooting mode switches the screen output. HDMI gets different treatment. Shooting mode's event table jumps to a separate playback-only mode instead, and the code that picks the screen never chooses HDMI, even though the display code has a routine that switches output to HDMI. The `hdmi-liveview` patch changes four values so shooting mode handles HDMI the way it handles analog video. `usb-peek` swaps an unused MTP command for a new one, `0x9484`, whose handler (`asm/peek.s`) sends back any range of memory. It replaces a debug command that only the internal serial console can reach. `NOTES.md` traces each step with addresses.

Other projects that made this possible:

- [cmdada/em10-fw](https://github.com/cmdada/em10-fw), a firmware map, emulator and plugin loader for the E-M10 Mark I, the E-M5's closest sibling.
- [fishcu/oly_fw_analysis](https://github.com/fishcu/oly_fw_analysis), shared research across Olympus bodies, including a USB live view patch for the OM-3.
- [xulfr/om-emu](https://github.com/xulfr/om-emu), an emulator and notes on the firmware container.
