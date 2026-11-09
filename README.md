# Mark One

Turns an original Olympus OM-D E-M5 (Mark I, 2012) into a Mac webcam over a single USB cable, with the camera's own lens, sensor and color. Out of the box the camera can't do this: it refuses to shoot while HDMI is plugged in, and its USB connection only transfers files. So this project changes its firmware, and a Mac app called Mark One turns the camera into a camera any video app can pick.

## Where it stands

Mark One works end to end, with nothing to click. It sits in the menu bar and can open at login. Plug in the camera with its USB Mode set to MTP, switch it on, and open a video app. Mark One:

1. connects through ImageCaptureCore, which works inside the App Store sandbox
2. switches the camera to live view with USB connected, so movies don't write to the card and have no time limit (that last part is still untested)
3. presses the camera's REC button for you when an app starts using the Mark One camera
4. follows the camera's 1080p, 30 frames per second H.264 movie stream straight out of its memory
5. decodes it with libavcodec
6. publishes it as the "Mark One" camera through a Core Media IO camera extension, for FaceTime, Zoom, OBS, QuickTime and so on

Recording stops 5 seconds after the last app stops using the camera, and when you quit Mark One. Mark One notices when the camera is switched back on or plugged in again and sets it up again. The camera's power switch turns it off as usual, and Mark One says so. Video reaches the Mac about 200 ms after it happens.

All of this rests on one firmware change, `usb-tools`, which adds USB commands that read and write camera memory and run code. Everything else Mark One does lives in the camera's memory only, and switching the camera off undoes it. Flashing modified firmware can brick a camera, so read the risks in `NOTES.md` first.

## What's left

### Make webcam mode seamless

The goal is software that feels like magic: plug in the camera, open a video call, and it works, with nothing to press on the camera or in Mark One.

- **Webcam mode in the firmware.** Today Mark One rewrites camera memory every time it starts. A firmware build with webcam mode built in would be faster and sturdier: it would enter webcam mode by itself when Mark One connects, and skip card writes and the time limit only in that mode.
- **Install the firmware from Mark One.** Olympus's own updater installs firmware over USB, so the camera has a USB update path. Work out its protocol, then let Mark One check the camera's firmware and offer to install the webcam firmware, with no SD card. Olympus's firmware can't be shipped in the app, so Mark One would download the stock file from Olympus (as `scripts/setup.sh` does), patch it on the Mac, and send it to the camera. This needs care: a failed flash can brick the camera, and App Review will want to see a clear explanation.
- **Power.** The E-M5 doesn't run from USB power, so long calls drain the battery. Look at a dummy battery with a power adapter, and show the battery level in Mark One.
- **Picture controls.** Exposure, white balance, picture mode and focus from Mark One, through the same camera API the firmware's own menus use.

### Test

- **Recording limit.** Stream for more than 30 minutes and check that the time-limit patch holds. Also check what happens around 27 minutes, when the movie writer would reach 4 GB even though nothing goes to the card.
- **Card space.** After a long session, check that the card's free space didn't shrink.

### Before the App Store

- Credit FFmpeg in the app, link to its source and include the LGPL 2.1 text. Mark One ships libavcodec as separate, unmodified dynamic libraries for this reason.
- Remove the Downloads entitlement, which only the debug capture uses (the `SaveCapture` default), or put the capture behind a debug build.
- A Release build, screenshots and App Review notes that explain the firmware requirement.
- Decide how people get the `usb-tools` firmware onto their camera until Mark One can install it itself.

### Open questions

- Why Apple's video decoders reject this stream. The hardware decoder rejects every frame and the software decoder about 1 in 100, while libavcodec decodes all of them. `NOTES.md` lists what has been ruled out.
- `hdmi-liveview`, which should let the camera show live view over HDMI while shooting, is built but has never been tried on a camera. USB made it unnecessary for the webcam, but it would help anyone using a capture card.

## Mark One

`mac/MarkOne` holds the app, its camera extension and `markone-feed`, an older tool that pipes frames from `scripts/stream.py`. Build it with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
scripts/build-libavcodec.sh          # once: FFmpeg's H.264 decoder, about a minute
cd mac/MarkOne
cp Local.xcconfig.example Local.xcconfig   # then set DEVELOPMENT_TEAM
xcodegen generate
xcodebuild -project MarkOne.xcodeproj -scheme MarkOne -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build
cp -R "build/Build/Products/Debug/Mark One.app" /Applications/
```

The app has to run from `/Applications` to install its camera extension. It installs its camera extension when it opens; approve it the first time in System Settings > General > Login Items & Extensions > Camera Extensions. Quit Mark One normally rather than force-quitting it. Force-quitting it mid-session can leave macOS's camera service stuck, and then the camera doesn't show up again until you unplug it.

## Running it

You need [uv](https://docs.astral.sh/uv/), `curl` and `xz`. uv installs Python and the dependencies (`numpy`, and `pyusb` with a bundled libusb) for you.

Install the dependencies, then fetch and unpack the stock v2.3 firmware. The firmware is Olympus's, so it isn't in this repo; the script downloads it and checks its hash.

```sh
scripts/setup.sh
```

Build the patched firmware with any combination of patches. The script checks every byte it replaces, so it won't patch anything other than stock v2.3.

```sh
uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN patched/hdmi-liveview/E0972300.BIN hdmi-liveview
uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN patched/usb-tools/E0972300.BIN usb-tools
```

Check that repacking the unmodified firmware reproduces the original file:

```sh
uv run scripts/build.py --roundtrip fw/OLY_E_097_2300_0000_0000.BIN
```

To flash, copy the `.BIN` into a `DCOLYMP` folder on the SD card, unplug USB, hold OK while turning the camera on, and let go when the light flashes. The light never signals the end: wait about 5 minutes, take the battery out and back in, and check the version under Settings > Firmware. Restore by flashing the stock file the same way, or with Olympus's updater. `NOTES.md` has the full test plan.

## Talking to the camera over USB

The Python scripts came first and are still the quickest way to experiment. `scripts/ptp.py` sends raw PTP commands. Set the camera's USB Mode to MTP and connect it. macOS's camera service, `ptpcamerad`, claims every camera as it connects; the script stops it and takes the camera.

```sh
uv run scripts/ptp.py info                  # model, firmware and supported commands
uv run scripts/ptp.py peek 0x602adef8 4     # read camera memory (needs usb-tools)
uv run scripts/ptp.py poke 0x7e400000 code.bin   # write camera memory
uv run scripts/ptp.py run 0x7e400000 1 2    # call a function, print d0 and a0
uv run scripts/ptp.py shoot                 # live view with USB connected; movies no longer write the card
uv run scripts/ptp.py output evf            # 800x600 viewfinder image instead of 568x480
uv run scripts/live.py                      # live view in the browser at http://localhost:8000
uv run scripts/live.py --movie              # 1080p while the camera records a movie
uv run scripts/stream.py --raw | mac/viewer/viewer   # 1080p at 30 fps while recording, lowest delay
```

Build the viewer once with `swiftc -O -o mac/viewer/viewer mac/viewer/main.swift` (needs Xcode or the command line tools).

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

The camera's shooting mode already sends live view to the analog video port: when that cable goes in, shooting mode switches the screen output. HDMI gets different treatment. Shooting mode's event table jumps to a separate playback-only mode instead, and the code that picks the screen never chooses HDMI, even though the display code has a routine that switches output to HDMI. The `hdmi-liveview` patch changes four values so shooting mode handles HDMI the way it handles analog video. `usb-tools` swaps three MTP commands that only Windows uses for new ones (`asm/usb.s`): `0x9484` reads memory, `0x9485` writes it, and `0x9486` calls a function. They replace a debug command that only the internal serial console can reach. With them, new code can be loaded into RAM and run over USB, and a restart undoes it.

The camera's movie recorder encodes 1080p H.264 into a ring buffer in memory before writing it to the card. Mark One switches off the card writes and reads the frames out of that ring as they're encoded, checking each frame's header to tell a fresh frame from an old one. To press REC, it puts a key event on the firmware's key queue, the same message a real button press produces. `NOTES.md` traces each step with addresses.

Other projects that made this possible:

- [cmdada/em10-fw](https://github.com/cmdada/em10-fw), a firmware map, emulator and plugin loader for the E-M10 Mark I, the E-M5's closest sibling.
- [fishcu/oly_fw_analysis](https://github.com/fishcu/oly_fw_analysis), shared research across Olympus bodies, including a USB live view patch for the OM-3.
- [xulfr/om-emu](https://github.com/xulfr/om-emu), an emulator and notes on the firmware container.
