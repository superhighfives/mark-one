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
- Confirmed on the E-M5 (1.5 to stock 2.3, 2026-11-06): the card updater
  works. Release OK once the light starts flashing. The light kept flashing
  for 25 minutes and never signaled the end; pulling the battery and powering
  on normally showed 2.3. Start with no USB cable attached. OM Workspace
  wants a kernel extension on current macOS (which needs reduced security),
  so the card is the easier route.

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

### Shooting with USB connected (working, 2026-11-06)

`ptp.py shoot` switches an MTP-connected camera to live view without
dropping USB. No reflash: it only changes RAM, and a restart undoes it.

- PC mode has sub-states 0x6000-0x600c, each with its own event list
  (table of `{state, list, count}` at 0x7eef371c). Sub-state 0x6004's list
  (0x7eef30ec, 8 entries) maps events 0x03000048/49 to `startCameraControl`
  (0x7edd5c96), which requests 24 (PC_CAM_SHOOTING); 0x0300004a requests 25
  (PC_CAM_PLAY) and 0x0300004b requests 23 (PC_RETURN).
- `completedPcConnect` (0x7edd5bf9) enters 0x6004, or 0x6005 when the
  connection type (0x605f0d14: 1 Storage, 2 MTP, 4 Print, from the USB
  prompt) is 2. 0x6005's list (0x7eef316c, 3 entries) is a subset of
  0x6004's without the camera control events.
- The events come from notification group 2, id 50 (value 1 or 2 -> 0x48 or
  0x49, 3 -> 0x4a, other -> 0x4b), translated by 0x7edd55ba (a `calls`
  entry). The USB stack registers it as a callback (0x7edd5564). The serial
  console command `nfPcCbk` (0x7edd568c) calls it with the PC mode object
  at 0x605f0d3c, whose method +4 (0x7edda7f9) sends a 20-byte message to
  queue 5, so calling it from the USB task is safe.
- `shoot`: write 0x7eef30ec and 8 into 0x6005's table row (0x7eef375c,
  0x7eef3760) through the cache, then run 0x7edd55ba with d0 = 2, d1 = 50,
  a0 = *(0x605f0d3c), a1 = 1. The USB session stays up and the panel buffers
  start updating.
- Reading and writing cached variables needs code running on the camera:
  `ptp.py` loads two tiny helpers at 0x7eaaab74 (read) and 0x7eaaab7a
  (write).
- `scripts/live.py` streams the panel buffer on screen (index at 0x605b5054,
  address table at 0x7e932b84: 0xbd742b00, 0xbd8c2b00, 0xbd5c2b00) as motion
  JPEG at 27 frames per second, 568x480.

### Looking for a higher resolution frame (2026-11-06)

Memory diffing over USB (two snapshots, compare 64 KB blocks) in shooting
mode with USB connected, photo and movie mode, 0xa0000000-0xbe000000:

- Panel buffers 0xbd5c2b00/0xbd742b00/0xbd8c2b00: the 568x480 picture
  (smaller and 16:9 in movie mode).
- Movie buffers `m_aulYuvAddr` (set up at 0x7e7a050c): three slots of
  3,526,656 bytes from 0xbc67a840, but only 1,254,400 bytes are written in
  live view, in photo and movie mode alike. Rows are 3,584 bytes (two
  1,792-byte halves); the bytes are bit-packed (period 16, byte 15 nearly
  constant), so it looks like packed sensor data rather than YCbCr. Not
  decoded.
  Decoding: it is close to Panasonic's raw compression (dcraw
  `panasonic_load_raw`): 16-byte blocks of 14 pixels, two 12-bit start
  values and 8-bit steps with 2-bit shift codes. Reading each block from
  its top bit down gives a 1568x700 Bayer-like image (rows skipped) with
  clear same-color correlation (0.35 of noise level at distance 2, 0.2
  vertically), but the even pixels drift within each 14-pixel block
  (337 to 980), so some detail of the format differs. Other bit orders
  remove the drift but lose vertical coherence. Not finished: at best it
  gives about 1568x700 of unprocessed sensor data, which needs white
  balance, demosaicing and color correction on the computer.
- Four small buffers of 52,224 bytes from 0xbd091840.
- 0xa0090000, 1.3 MB: repeats every 256-384 bytes; not an image.
- Nothing else of frame size changes. No 1080p image exists in live view
  unless the HDMI output runs.
- `CameraCommon::changeOutLine(0x08)` (API object at 0x602b243c, method +16,
  0x7eaa6644) returns 0xf0000001 with no HDMI cable, and the HDMI buffers
  stay untouched. `changeOutLine(0x01)` returns 0 (back to the panel).

### Viewfinder output: 800x600 over USB

`changeOutLine(0x10)` (internal EVF) works from USB in PC shooting mode
and returns 0. The screen buffer then holds the viewfinder image: 800x600
in photo mode, 800x450 plus a dark band in 16:9 movie mode, against
568x480 for the rear screen. The output stays on the viewfinder (checked
for 12 s). `ptp.py output evf` / `output lcd` switch it; `live.py` detects
the picture size and streams 800x450 at about 28 frames per second.

Panel sizes come from per-panel functions in the display driver (for
example 0x7e780e16 reports 90x15, 800x600, 640x480), called directly from
0x7e77e9c9 and 0x7e7898be, so changing them means changing code.
0x7e782d7f is an identical copy. Patching both in RAM to report 1024x768
(poke 0x7e780e22 `0004f0712c0003f8`, 0x7e782d8a `2c0004f0712c0003`) and
switching the output LCD -> EVF hangs the display task: `changeOutLine`
never returns and the USB task blocks with it. A battery pull recovers. The
display hardware setup can't take a size beyond the panel's.

### 1080p frames while recording a movie (2026-11-06)

While the camera records a movie (MOV, Full HD), memory diffing finds:

- The movie slots (0xbc67a840 + n * 3,526,656) fully used: packed sensor
  data again, rows of about 2,688 bytes (about 2352x1312 pixels).
- 0xa5610000-0xa6250000 and around 0xa52b0000, 0xaa2a0000: noisy data with
  many 00 00 01 start codes: the H.264 stream.
- From about 0xa66b0000 to 0xaa4d0000: a run of processed 1080p frames,
  one every 0x300000 bytes, NV12: Y plane 1920x1088 (1080 used, stride
  1920), then interleaved Cb Cr at +1920*1088. One frame starts at
  0xa6cd3600. Full color, sharp, the camera's own processing.

Frame ring (found by watching memory near pointers to the frames):

- 0xa07870a0: header `{1, 0xa52b1c00, 0x1400000, 0xa66b1c00, ...}`, which
  looks like the H.264 stream ring: 20 MB from 0xa52b1c00 to 0xa66b1c00.
- 0xa07870b8: 32 entries of 24 bytes, `{Y address, Y stride (1920), CbCr
  address, CbCr stride, timestamp (90 kHz, +3003 per frame = 29.97 fps),
  frame number}`. Frames are packed back to back, 3,133,440 bytes each
  (1920x1088x1.5), 18 of them from 0xa6cd3600. The newest frame has the
  highest frame number.
- 0xa07873b8: a second ring of 16-byte entries `{address, timestamp,
  0x1e00, number}` near 0xaa43xxxx, 25 per second: probably audio.

`live.py --movie` reads the newest frame (two transfers, 2 MB + 1 MB) and
streams it at about 8.4 frames per second at 1920x1080.

H.264 stream (`scripts/stream.py`):

- Frame descriptors: 60 entries, 244 bytes apart, from 0xa07e5180. Frame
  number at +4, address at +8 (repeated at +12), timestamp (90 kHz) at -52,
  size at -48. The frame being encoded has the placeholder size 0xbf440.
- Video ring: 0xa52b1c00 to about 0xa5560000 (holds about 45 frames, so the
  oldest descriptors point at overwritten data); audio follows from
  0xa5611380 (descriptors from 0xa07e9188, 0x1e00 bytes each).
- Frames are Annex B: access unit delimiter, then SPS (High profile) and
  PPS on keyframes, every 15 frames; about 75 KB per frame at 20 Mbps.
- The descriptor table lags the encoder: about once every 60 frames an
  entry is updated 300-430 ms late (its number changes first, so it still
  describes the frame from 60 frames earlier), and a finished frame's size
  can be corrected afterwards. Anything that waits for the table stalls
  the picture, and anything that trusts it reads the wrong bytes.
- So `stream.py` follows the stream itself and uses the table only as a
  hint. Each frame's SEI picture timing (cpb_removal_delay, +2 per frame,
  2..60) and slice frame_num (resets at each IDR, every 15 frames) must
  follow the previous frame's. That pair repeats every 30 frames, about
  one lap of the ring, so the streamer also remembers the first 1 KB of
  every frame it has sent, by address: a frame that matches is left over
  from an earlier lap. A frame ends where the next header that follows it
  begins (table size tried first, then a search). The ring wraps to
  0xa52b1c00 with 0x95000-0xc4000 bytes left below 0xa5611380 (not a fixed
  threshold), so the ring start is tried as the next frame only within
  1 MB of the top, and only with the table's size for the frame before.
- Result: 20-second captures with no decode errors, frames 33 ms apart
  (p95 about 63 ms), and one resync of up to a second right after start.
- Result: 1920x1080 at 29.97 frames per second, decodable by ffmpeg.

Display latency (measured by filming a millisecond clock on the Mac's
screen): frames reach the Mac about 200 ms after the scene, including the
screen's own refresh. The ffmpeg command line (ffmpeg, ffplay) then holds
back about 20 frames before output, even with low_delay, one thread and no
probing, which made ffplay about a second behind. Decoding one frame at a
time with PyAV (libavcodec) returns each frame immediately, in about
1.5 ms. Apple's hardware decoder (VideoToolbox, also through
AVSampleBufferDisplayLayer) fails on every frame of this stream; it is
High profile with CAVLC and custom scaling matrices, which may be why.
`stream.py --raw` decodes with PyAV and writes NV12; `mac/viewer` shows
each frame as it arrives.

`stream.py` also rewrites the SPS to add bitstream restriction fields (no
reordering, one-frame buffer); the camera's SPS leaves them out, so
decoders may otherwise assume they need a 16-frame buffer.

Card writes: the movie writers call fileif_fwrite (0x7e69f3bb) from
QT_FILE (0x7e7a75b2) and MOV_FILE (0x7e7c04ca), then check the returned
count against the size in d1. Replacing each call with `mov d1,d0` and
nops (in RAM, `ptp.py shoot` does it) leaves recording and the stream
running and the clip on the card empty ("picture error" in playback).
Not yet checked: whether the file system still reserves the clip's space,
and whether the 29-minute limit still stops recording.

## Mark One (macOS camera)

`mac/MarkOne` (XcodeGen: `xcodegen generate`, then build the MarkOne and
markone-feed schemes; set DEVELOPMENT_TEAM in `Local.xcconfig`):

- Mark One.app installs a Core Media IO camera extension
  (com.superhighfives.markone.camera). The app must run from /Applications;
  the user approves the extension in System Settings > General > Login
  Items & Extensions > Camera Extensions.
- The extension publishes the "Mark One" camera with a source stream
  (what apps see) and a sink stream. Frames from the sink go straight to
  the source; without frames for 0.5 s it shows a dark gray placeholder.
  Format: 1920x1080 420f (full range NV12), 30 frames per second.
- `markone-feed` finds the device by its fixed UID, opens the sink with
  CMIOStreamCopyBufferQueue and enqueues each NV12 frame from stdin:
  `uv run scripts/stream.py --raw | markone-feed`. Works in QuickTime.

## Starting a recording from the computer (not working yet)

- OlyApiShootingController::ctrlRelease (controller from 0x7ead145d,
  vtable slot 256; `asm/release.s`) refuses while recording ("API
  sequence" 0x602b1ff4 must be 0 or 1; recording sets 0x10). From idle it
  returns 0 for any releaseGo with takeMovie = 1 and key_movie = 11, with
  or without key_1st/key_2nd, but no recording starts. It seems to set up
  remote release rather than press a key.
- Posting event 0x01000022 (movie key; 0x01000023 is probably its
  release) to the mode manager's queue with `asm/post.s` does nothing in
  PC shooting. The mode manager's movie key handler
  (startCtrlReleaseSubAppModuleRelease, around 0x7edcc128) reads the key
  from 0x605f0c4c rather than the message, and keys reach events through
  a "direct mode" mapping (0x7edcf0d7). Next: trace how the key task
  delivers the movie key.

Next: start recording from the computer, the recording time limit, and
moving the streamer into the app (needed for the App Store).

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

### Patch: usb-tools (working)

Flashed 2026-11-06. Results on the camera:

- `info` lists 0x9484-0x9486. A string read through the uncached mirror
  (0xbf127c8c) matches main.bin at 0x7f127c8c, which confirms the mirror is
  0x40000000 above the cached view.
- Reads run at 36.5 MB/s with 1.5 MB transfers (20 MB/s with 64 KB): 23
  full 1024x768 panel buffers or 8.8 raw 1080p frames per second. A single
  transfer of 1.5 MB works.
- poke and run work: a 7-byte function written at 0x7eaaab74 (the unused
  end of the handler space) and run with d0 = 2, d1 = 3 returned d0 = 5.
- With USB connected (PC mode, live view off), all three panel buffers still
  hold the last live view frames: 568x480 of picture plus a black band to
  640, at the top left of the 1024x768 buffer, Y Cb Y Cr byte order
  (`scripts/yuv2png.py` converts them). The rest of each buffer is never
  written. So the panel buffers are low resolution, about 568x480. The
  1080p HDMI buffers hold untouched memory until HDMI output runs.
- 0x602adef8 reads 0 in PC mode; the current buffer index (0x605b5054) is 2.

### Patch: usb-tools

Three commands in MTP mode, from `asm/usb.s`:

- 0x9484 peek: param 1 = address, param 2 = length; sends `length` bytes.
- 0x9485 poke: param 1 = address; writes the data the computer sends.
- 0x9486 run: param 1 = function, params 2-5 = d0, d1, a0, a1; calls the
  function with `calls` and returns d0 and a0 as response parameters.

Together they let new code go into RAM and run without reflashing, and a
restart wipes it. They take over the 0x9801, 0x9802 and 0x9805
registrations in the MTP setup function (only Windows MTP browsing uses
them) and their entries in the advertised list:

| Address | Bytes | Change |
|---|---|---|
| 0x7f0d4bbc | 05980000 -> 84940000 | register 0x9484 instead of 0x9805 |
| 0x7f0d4bc6 | 34640d7f -> e3aaaa7e | handler -> peek |
| 0x7f0d4b7d | 01980000 -> 85940000 | register 0x9485 instead of 0x9801 |
| 0x7f0d4b82 | 01 -> 02 | direction: computer to camera |
| 0x7f0d4b87 | 21620d7f -> 1cabaa7e | handler -> poke |
| 0x7f0d4b92 | 02980000 -> 86940000 | register 0x9486 instead of 0x9802 |
| 0x7f0d4b97 | 01 -> 00 | direction: no data |
| 0x7f0d4b9c | b4620d7f -> 46abaa7e | handler -> run |
| 0x7f128970 | 01980298 -> 85948694 | advertised list |
| 0x7f128976 | 0598 -> 8494 | advertised list |
| 0x7eaaaae3 | 145 bytes | handlers from `asm/usb.s` |

The handlers overwrite the `sdk api changeOutLine` debug command
(0x7eaaaae3-0x7eaaab8e, 171 bytes), referenced only from the `sdk api`
command table at 0x7ecda9ec, which the serial console uses.

USB transfer functions (from the 0x1016 SetDevicePropValue handler at
0x7f0df9bb and the TPC code around them):

- 0x7f0d9c37 send: a0 = pointer, d0 = chunk, d1 = total. Callers use
  `call ...,[d2,d3,a2,a3],24`.
- 0x7f0d9cfa receive start: reads the data container header, returns
  d0 = data length (0 on error). `call ...,[d2,a2],16`.
- 0x7f0d9d70 receive: a0 = pointer, d0 = length; returns d0 = 1 on success.
  `call ...,[d2,d3,a2],20`.
- Response: code (u16) at (a1), parameter count at (12,a1), parameters
  from (16,a1) (see the 0x1006 GetNumObjects handler at 0x7f0decc2).

Address rule: the transfer driver (0x7f0da626, and 0x7f0e4a19 which logs
"[USB]DATA Cache Address") refuses odd addresses and addresses with bit 30
set. 0x40000000-0x7fffffff is the cached view of RAM;
0x80000000-0xbfffffff is presumably the uncached mirror of the same
memory, 0x40000000 higher (the firmware's own globals appear at both
0x60xxxxxx and 0xa0xxxxxx). So peek 0x602adef8 as 0xa02adef8; `ptp.py` does
this translation. The video buffers (0xbd..., 0xbb..., 0xbc...) are already
uncached. peek answers 0x201d for a refused address instead of hanging;
poke can't refuse, because the data has already been sent, so `ptp.py`
checks first. Confirming the mirror: peek a string in the code at
0xbexxxxxx and compare it with main.bin at 0x7exxxxxx.

`run` calls the target with `calls`, so it must build its own frame
(start with `movm`/`add`, end with `ret`), like a command handler.
Firmware functions reached with `call addr,[regs],N` don't, and calling
them directly corrupts the stack; wrap them in uploaded code instead.
Uploaded code should go into code that never runs (more debug commands),
written through the uncached mirror, so no stale cache lines exist for it.

Build the handlers:

```sh
T=toolchain/install/bin
$T/mn10300-elf-as -o asm/usb.o asm/usb.s
$T/mn10300-elf-ld -Ttext=0x7eaaaae3 --defsym tpc_send_data=0x7f0d9c37 \
  --defsym tpc_recv_start=0x7f0d9cfa --defsym tpc_recv_data=0x7f0d9d70 \
  -e peek -o asm/usb.elf asm/usb.o
$T/mn10300-elf-objcopy -O binary asm/usb.elf asm/usb.bin
```

Absolute call targets must come from the linker (`--defsym`); a `.set`
constant gets encoded as a raw displacement.

Unknowns: what happens on a read from unmapped memory. Start with small reads of
known memory: `info`, then `peek 0x602adef8 4`, then a string in the code.

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

- HDMI has its own triple buffer at 1920x1080, 4,147,200 bytes each
  (2 bytes per pixel, YCbCr 4:2:2): M_HDMIVIDEOBASE1 0xbba06a00,
  M_HDMIVIDEOBASE2 0xbbdfb200, M_HDMIVIDEOBASE3 0xbc1efa00 (movie debug
  dump at 0x7e7a2aad). These are the best-quality frames to aim for: full
  1080p, the same image the HDMI port sends. They are probably only filled
  while HDMI output is active, so with the hdmi-liveview patch they may be
  readable over USB with no cable in the capture card at all.
- Bandwidth: a 1080p 4:2:2 frame is about 4 MB, so USB 2.0 (roughly 30-40
  MB per second in practice) gives under 10 frames per second raw. Smooth
  1080p over USB needs the camera's hardware JPEG encoder; raw frames are
  fine for confirming the image and for stills.

### Mac side

`scripts/ptp.py` speaks raw PTP over libusb (`info`, `peek`). For the real
webcam, ImageCaptureCore's `requestSendPTPCommand` (ICCameraDevice) can send
any PTP command, so a small app can poll 0x9484 and publish frames through
a CoreMediaIO camera extension.

## Next

The goal is image quality: the camera's lens and color, not a cheap webcam
image. HDMI through the Elgato gives 1080p video with the least new code.
USB is the cable-free route, aiming at the 1080p HDMI buffers.


1. Run the test plan on a camera running stock 2.3.
2. If HDMI stays dark: trace GUI message 110 handling in the shooting GUI app.
3. If it works but shows overlays: find the INFO display mode for HDMI.
4. USB: trace the PSP JPEG path in `CapThr_ThroughImage` (where the JPEG
   lands, how big it is, what turns it on) and the movie debug buffer dump.
5. USB: find what happens to the USB session if a PC-mode handler requests
   PC_CAM_SHOOTING (request 24) after connecting.
6. USB: flash usb-tools, run `ptp.py info` and small peeks, then read
   0x602adef8 and the video buffers while the camera is in shooting mode.
7. USB: find a higher resolution live frame than the 568x480 panel buffer:
   the HDMI 1080p buffers (with hdmi-liveview), or the movie pipeline.
