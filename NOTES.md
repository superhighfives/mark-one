# E-M5 (Mark I) as a Mac webcam

Research notes for getting live video from an original Olympus OM-D E-M5
into macOS as a webcam by patching the camera firmware. Everything here
targets firmware 2.3, so update the camera to 2.3 before flashing anything.

## Stock behavior (dead ends without firmware changes)

- HDMI: manual p.74, "You cannot shoot pictures or movies when the HDMI cable
  is connected." HDMI only shows playback.
- USB: MTP mode exposes file transfer only (gphoto2 dump, libgphoto2
  `camlibs/ptp2/cameras/olympus-e-m5.txt`). Manual: "Camera controls can not be
  used while the camera is connected to a computer."
- Not supported by Olympus OM-D Webcam / OM Capture. No built-in Wi-Fi.

## Firmware

- `fw/OLY_E_097_2300_0000_0000.BIN` (v2.3), sha256 `cb158dbd…e535`, from the
  xdel.ru mirror (the official OMDS URL returned 403).
- Unpacked with `tools/olyfw.py` (from xulfr/om-emu) into `unpacked/`. All five
  block hashes match fishcu/oly_fw_analysis `provenance/firmware-inventory.json`.
  Block 0 (`main.bin`, 14 MB, container load 0x902c0000) is the main code.

## Leads in main.bin strings

- App modes: `SUB_APP_PLAY_HDMI` / `MNG_START_CAM_PLAYHDMI` is the forced
  HDMI playback mode, entered on `RCV APPEVENT_CAMST_HDMI_CONNECT`.
- Display layer treats HDMI as one output among
  `IDLE/TFT/NTSC/PAL/HDMI/EVF`, with HDMI main/sub/OSD areas, so live view on
  HDMI may only be gated by the mode switch.
- `SUB_APPCHG_PC_CAM_SHOOTING`, `SUB_APPCHG_PC_CAM_PLAY`: transitions from PC
  mode into shooting. Check whether this is a dormant PC-control mode.
- USB: `OLPTP` vendor layer (`[TPC_OLPTPAPI] ADJ_P15740_COM_VENDOR_OPERATION`),
  `[TPCFirmup]` ops, `SAICAS_TPC` / `TPCalib` factory channel.
- Same task layout as the E-M10 Mark I (see cmdada/em10-fw notes).

## Disassembly setup

- Toolchain: `toolchain/install/bin/mn10300-elf-objdump` (binutils 2.43.1,
  built with `--with-system-zlib` and `MAKEINFO=true`).
- Runtime base of main.bin is **0x7E421020** (`scripts/findbase.py`: 13,038
  pointers hit string starts vs 3,060 for the runner-up; same base as E-PL5).
- Disassemble: `objdump -D -b binary -m am33-2 --adjust-vma=0x7E421020
  --start-address=X --stop-address=Y unpacked/main.bin`
- Helpers in `scripts/`: `xref.py` (string to referencing addresses),
  `words.py` (dump words, resolve string pointers), `findimm.py` (find a 32-bit
  value anywhere).

## Findings in code

Full annotated disassembly: `disasm/main.s` (string pointers labelled,
`fn_` labels at call targets). API method names: `disasm/api-ids.txt`
(IDs like 0x01010b = group 1, class 1, method 11; the name table is at
0x7ea13424).

### Mode manager (sub-app changes)

- Name tables at 0x7ef04578.., pairs `{value, name}`. SUB_APPCHG_*:
  BOOT 0x08000000, SHOOTING ..02, PLAY ..03, PLAYHDMI ..04, MISC ..05,
  PC ..06, PC_RETURN ..07, PC_CAM_SHOOTING ..08, PC_CAM_PLAY ..09.
- `setSubAppChgReqInfo` (fn 0x7edcce4d) takes a request number 1..25; jump
  table 0x7eeee820 maps it to a SUB_APPCHG event. Requests 12-15 shooting,
  16-18 play, 19 PLAYHDMI, 20-22 PC, 23 PC_RETURN, 24 PC_CAM_SHOOTING,
  25 PC_CAM_PLAY.
- `checkSubAppChg` (0x7edcce83): 25x25 byte table at 0x7eeee264,
  row = new request, col = previous. 0 ok, 1 forbidden, 2 not while USB is
  connected, 3 not while HDMI is connected. Request 19 needs HDMI connected;
  20-25 need USB connected. The table does **not** forbid shooting from
  PLAYHDMI.
- Requests 24/25 (PC shooting/playback) are never requested anywhere: dormant.

### Event tables per mode

16-byte entries `{event, 1, 1, handler}`:

| Table | Mode | Loaded by |
|---|---|---|
| 0x7ef0013c (23 entries) | ShootingCommon | 0x7edd6e02 |
| 0x7eef3a24 (20) | PlayCommon | 0x7edd5ec7 |
| 0x7eef4400 (21) | PlayHdmiCommon | 0x7edd6627 |

Connection events: 0x01050000/1 USB connect/disconnect, 0x01050002/3 analog
video connect/disconnect, 0x01050004/5 HDMI connect/disconnect.

ShootingCommon: analog video -> `receiveConnectChange` (0x7edc95eb, stays in
shooting and changes the display); HDMI connect -> 0x7edce387 (request 19,
PLAYHDMI); HDMI disconnect -> 0x7edce39d.

### Display output in shooting

- `receiveConnectChange` -> `checkChangeOutputDisplay` (0x7edc955f): desired
  target (0x7edc98c3) vs current (0x7edc99bb). If they differ, posts
  SUB_EVENT_REQ_CHANGE_DISPLAY (0x09000013) -> `receiveReqChangeDisplay` ->
  0x7edc97fe -> apply (0x7edc9a62).
- Target selector 0x7edc98c3 returns NON 0, TFT 1, VIDEO 2, EVF 3,
  INTERNAL_EVF 4. It never returns HDMI. VIDEO is chosen when
  `CameraCommon::getCompositeState` (API slot +44) returns 0 (connected).
- Apply 0x7edc9a62 maps target to GUI output type (TFT->1, VIDEO->3,
  EVF->2, INTERNAL_EVF->6) and sends GUI message 110.
- GUI dispatcher (0x7edf3d6f / 0x7edf3e6c / 0x7edf571d): type 4 ->
  `CCommon::doHdmiConnectChange` (0x7edf3f62), which calls
  `getHdmiState` and, when connected (0), `CameraCommon::changeOutLine(0x08)`
  then `setOutputType`.
- `changeOutLine` line values (debug command `sdk api`): LCD 0x01, EVF 0x02,
  composite 0x04, HDMI 0x08, internal EVF 0x10.
- `getHdmiState` / `getCompositeState` / `getUsbState` return 0 when connected.

### Other

- 0x02020501 is a status flag ("HDMI connected"), set by 0x7e78ba22 after a
  1 s debounce, read via 0x7e761b28. `isHdmiConnected` wrapper 0x7eaec1c6.
- CameraCommon API vtable at 0x7ecd7f78; slot order differs from ID order.
  Each wrapper logs its ID (`mov 65xxx,d0`). Known slots: +16 changeOutLine,
  +20 getDisplayDeviceState, +40 getUsbState, +44 getCompositeState,
  +48 getHdmiState. The API object comes from 0x7eaa65f0.
- Card updater: `DCOLYMP\E097????.BIN`, hold OK at power-on.

## Patch: hdmi-liveview (untested)

Built by `scripts/build.py`, into `patched/hdmi-liveview/E0972300.BIN`
(sha256 a22ea0b9…fdfd). Treats HDMI like analog video while shooting:

| Address | Bytes | Change |
|---|---|---|
| 0x7edc98d5 | 2c -> 30 | target selector reads getHdmiState instead of getCompositeState |
| 0x7edc9a9f | 03 -> 04 | VIDEO target goes to the GUI as output type 4 (HDMI) |
| 0x7ef00268 | 87e3dc7e -> eb95dc7e | ShootingCommon HDMI connect -> receiveConnectChange |
| 0x7ef00278 | 9de3dc7e -> eb95dc7e | ShootingCommon HDMI disconnect -> receiveConnectChange |

6 decoded bytes + 4 checksum bytes differ. `--roundtrip` on stock rebuilds
the original byte for byte. Analog video out stops working in shooting mode
with this patch (it now follows HDMI).

Risks and unknowns: whether live view renders at HDMI sizes in shooting
mode; the GUI's info overlays; a crash or hang when HDMI is plugged in.
Booting without HDMI follows unchanged code, so restoring stock should stay
possible (`patched/stock/E0972300.BIN`, same card method or the official
updater).

### Test plan

1. Update the camera to stock 2.3 with Olympus's updater (needs CB-USB6).
2. Set Custom menu > HDMI > HDMI Out 720p, HDMI Control Off.
3. Copy `patched/hdmi-liveview/E0972300.BIN` to `DCOLYMP/` on a freshly
   formatted card, full battery, hold OK and power on; wait for the LED.
4. Power on normally without HDMI; confirm the camera works.
5. Elgato connected to the Mac, camera in shooting mode, plug in HDMI.
   Watch the Elgato preview.
6. Restore: `patched/stock/E0972300.BIN` the same way.

## Prior art

- cmdada/em10-fw: E-M10 Mark I firmware map, emulator, SD-card plugin loader,
  OK+power recovery report.
- fishcu/oly_fw_analysis: shared research; OM-3 USB live view patch (kred, PTP
  op 0x9484 returning JPEG frames) in `docs/protocols/om-3/TETHERING.md`.
- xulfr/om-emu: emulator, container format and flashing notes.
- mu-43 "Modified firmware, looking for users" thread: active community.

## USB path

Goal: a vendor command (proposed number 0x9484, the live view command
later Olympus bodies use) that returns the current live view frame while
the camera stays in shooting mode with USB connected.

### Command lists and registration

- Advertised command lists at 0x7f128916.., picked by connection mode in
  0x7f0e0773: modes 0/5 -> 29 commands (standard + 0x9116-0x9125, firmware
  update), 1 -> 18 (standard), 2/3 -> 11 (printing), 4 -> 20 (MTP,
  0x9801-0x9805), 6 -> 33 (standard + 0x91xx + 0x902c-0x902f). No 0x94xx
  remote control or live view commands exist.
- Handlers are registered per mode at runtime: a setup function clears the
  list (0x7f0d9b38), then calls `register` (0x7f0d9ab7) per command with
  d0 = command, d1 = data direction (0 none, 1 camera to computer,
  2 computer to camera), a1 = flag, a0 = handler. The list is a linked list
  (no fixed size); registering an existing number replaces it. Example setup
  functions: 0x7f0d4a5b, 0x7f0d4bd2; the Olympus 0x91xx block is registered
  around 0x7f0d49a4.
- Handler shape (see 0x9801's handler at 0x7f0d6221): a0 = request
  (parameters at +16, +20, ...), a1 = response. Get a buffer from
  0x7f0d9be7, send with 0x7f0d9c37(a0 = pointer, d0 = chunk length,
  d1 = total length), free with 0x7f0d9c10, then write the response code
  (0x2001 OK, 0x2002 error) as a u16 at (a1) and 0 at (12,a1).
- The send function streams: the first call sets the total length and
  later calls send further chunks from any pointer, so a frame buffer can be
  sent in place.

### Staying in shooting mode with USB connected

- SUB_APPCHG -> app start mapping (0x7edc74f9, jump table 0x7eeea934):
  PC_CAM_SHOOTING (0x08000008) starts the ordinary shooting app
  (MNG_START_CAM_SHOOTING), PC_CAM_PLAY starts playback. The transition
  table allows PC_CAM_SHOOTING only while USB is connected. Nothing requests
  it (request 24), so it's a ready-made but unused "shoot with USB attached"
  path.
- Unknown: whether the USB session (TPC task, `TPC_ON`) keeps running once
  the PC app hands over to shooting.

### Frame source candidates

- `CapThr_ThroughImage` "PSP JPEG": live view is encoded to JPEG in real
  time for the multi-preview grid (`setupMultiSetting`, `_isActivePspJpeg`,
  `allocPspJpegBufferHandle`). Hardware JPEG of live frames exists.
- Movie debug commands print "Video Buffer Address:%X DataSize:%d width:%d
  height:%d" for `M_VIDEOBASE`, `M_VIDEOBASE2`, `M_VIDEOEXTBASE`,
  `M_HDMIVIDEOBASE1-3`, which gives raw YC buffer locations and sizes.
- Raw frames are viable over USB 2.0: a 640x480 4:2:2 frame is about 600 KB,
  so roughly 30-50 frames per second at typical PTP throughput.

### Code space

The handler needs on the order of 100 bytes of new code. Options: the
E-M10 project's `load-padding` approach (padding between sections is not
copied to RAM unless the section table is extended), or overwriting code
that can't run on this body (UART-only debug commands, for example).

### Patch: usb-peek (untested)

Command 0x9484 in MTP mode returns `length` bytes from `address`
(parameters 1 and 2). It takes over the 0x9805 registration in the MTP
setup function and the 0x9805 entry in the advertised list, so no new
registration call is needed:

| Address | Bytes | Change |
|---|---|---|
| 0x7f0d4bbc | 05980000 -> 84940000 | register 0x9484 instead of 0x9805 |
| 0x7f0d4bc6 | 34640d7f -> e3aaaa7e | handler pointer -> 0x7eaaaae3 |
| 0x7f128976 | 0598 -> 8494 | advertised list: 0x9805 -> 0x9484 |
| 0x7eaaaae3 | 38 bytes | handler from `asm/peek.s` |

The handler overwrites the start of the `sdk api changeOutLine` debug
command (0x7eaaaae3-0x7eaaab8e, 171 bytes), referenced only from the `sdk api`
command table at 0x7ecda9ec, which the serial console uses. It mirrors the
stock 0x9801 handler: send with 0x7f0d9c37, reply 0x2001.

Build the handler:

```sh
T=toolchain/install/bin
$T/mn10300-elf-as -o asm/peek.o asm/peek.s
$T/mn10300-elf-ld -Ttext=0x7eaaaae3 --defsym tpc_send_data=0x7f0d9c37 -e peek -o asm/peek.elf asm/peek.o
$T/mn10300-elf-objcopy -O binary asm/peek.elf asm/peek.bin
```

Absolute call targets must come from the linker (`--defsym`); a `.set`
constant gets encoded as a raw displacement.

Unknowns: the largest length the send function accepts in one call, and
what happens on a read from unmapped memory. Start with small reads of
known RAM (for example 0x602adef8, 4 bytes).

### Live view buffers

- Movie debug code (0x7e7a2505) reports display video buffers of 1024x768,
  1,572,864 bytes each (2 bytes per pixel, YCbCr 4:2:2), triple buffered:
  table at 0x7e932b84 = M_VIDEOBASE 0xbd742b00, M_VIDEOBASE2 0xbd8c2b00,
  M_VIDEOEXTBASE 0xbd5c2b00. Current index at 0x605b5054, next-index table
  at 0x7e932b78; 0x7e7a0b34 returns a buffer not in use by the display.
- 0x602adef8 holds the address of the video buffer the display is showing.
  Set by 0x7e7860c5 (reprograms the display, used by movie playback through
  0x7e77e808) and by display setup 0x7e785c5e. Whether live view goes through
  this layer is not confirmed; peeking 0x602adef8 and the buffers while
  shooting will answer it.

### Mac side

`scripts/ptp.py` speaks raw PTP over libusb (`info`, `peek`). For the real
webcam, ImageCaptureCore's `requestSendPTPCommand` (ICCameraDevice) can send
any PTP command, so a small app can poll 0x9484 and publish frames through
a CoreMediaIO camera extension.

## Next

1. Run the test plan on a camera running stock 2.3.
2. If HDMI stays dark: trace GUI message 110 handling in the shooting GUI app.
3. If it works but shows overlays: find the INFO display mode for HDMI.
4. USB: trace the PSP JPEG path in `CapThr_ThroughImage` (where the JPEG
   lands, how big it is, what turns it on) and the movie debug buffer dump.
5. USB: find what happens to the USB session if a PC-mode handler requests
   PC_CAM_SHOOTING (request 24) after connecting.
6. USB: flash usb-peek, run `ptp.py info` and small peeks, then read
   0x602adef8 and the video buffers while the camera is in shooting mode.
7. USB: keep the USB session alive in shooting mode (PC_CAM_SHOOTING).
