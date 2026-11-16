# E-M5 (Mark I) as a Mac webcam

Research notes for getting live video from an original Olympus OM-D E-M5
into macOS as a webcam by patching the camera firmware. Everything here
targets firmware 2.3, so update the camera to 2.3 before flashing anything.

Open work is in `TODO.md`.

## Stock behavior (dead ends without firmware changes)

- HDMI: manual p.74, "You cannot shoot pictures or movies when the HDMI cable
  is connected." HDMI only shows playback.
- USB: MTP mode exposes file transfer only (gphoto2 dump, libgphoto2
  `camlibs/ptp2/cameras/olympus-e-m5.txt`). Manual: "Camera controls can not be
  used while the camera is connected to a computer."
- Not supported by Olympus OM-D Webcam / OM Capture. No built-in Wi-Fi.

## Firmware

- `fw/OLY_E_097_2300_0000_0000.BIN` (v2.3), sha256 `cb158dbd…e535`, from the
  xdel.ru mirror (the official OMDS URL returned 403). Since 2026-11-14,
  `scripts/setup.sh` asks Olympus's update server for it instead, as the
  app does ("Doing it from Mark One"): the same file.
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

Why VideoToolbox rejects the stream (error -12909, kVTVideoDecoderBadDataErr,
on every frame including IDRs) is still open. Ruled out by rewriting a
recorded clip and retesting with `ffmpeg -hwaccel videotoolbox` (the
software decoder accepts every variant): level, cropping, full range,
colour description, aspect ratio, fixed frame rate, AUDs, SEI, the whole
VUI, the PPS ID (2, renumbered to 0 in the PPS and every slice header),
the PPS scaling matrices (identical to the SPS 4x4 lists, so removable),
and the SPS scaling matrices. x264 streams with the same features (High,
CAVLC, custom matrices, no 8x8 transform, one reference, full range,
keyframe every 15) decode fine. So it's something in the slice data.
Frames end with a proper stop bit and no padding. The app needs a
software H.264 decoder (libavcodec).

Solved 2026-11-10 (see "Apple's decoder on exact frames" below): the
frames were cut with the recorder's table size, one byte too long, and
VideoToolbox rejects a frame with a nonzero byte after it.

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
- In-app pipeline (works, with no Python): Mark
  One.app, a menu bar app, finds the camera with ImageCaptureCore (sandbox-friendly,
  shares the camera with ptpcamerad instead of claiming the interface),
  sends the usb-tools commands with requestSendPTPCommand (`Camera.swift`),
  applies the same firmware setup as `ptp.py shoot` (`Firmware.swift`),
  follows the stream like `stream.py` (`Streamer.swift`), decodes with
  libavcodec (`FrameDecoder.swift`), and sends frames to the
  extension's sink (`CameraSink.swift`). ImageCaptureCore passes the
  vendor commands through and keeps up: all 30 frames a second arrive.
- `defaults write com.superhighfives.markone SaveCapture -bool YES` makes
  the next recording save the first minute of the stream to
  `~/Downloads/markone-capture.h264`, with `markone-capture.txt` listing
  each frame's size and whether the decoder rejected it.

VideoToolbox's software decoder rejects about 1% of the camera's frames
(error -8969, bad data): 16 of 1800 in a one-minute capture, always the
same frames when the capture is replayed. After a failure the session
rejects everything until it's recreated at the next keyframe, so each
failure loses up to 14 frames (the app repeats the last picture
meanwhile). libavcodec decodes those frames without error, even with
`-err_detect aggressive+careful`, and the pictures look like their
neighbors. The rejected frames have ordinary slice headers (identical to
neighbors apart from frame_num), no forbidden byte sequences, motion
vectors in the normal range, and are ordinary P frames using the common
PPS; giving the decoder all four PPSs up front doesn't help. x264 streams
with the same features, even at QP 2, decode fine. So it's a VideoToolbox
limitation with something in this encoder's slice data. (Wrong: see
"Apple's decoder on exact frames" below.)

OpenH264 2.7 (BSD license) decodes every frame without error but not
exactly: it matches libavcodec on Baseline streams, and differs on High
profile ones (x264 test streams and the camera's), so it doesn't fully
support High profile. libavcodec is the decoder that gets this stream
right, so Mark One uses it. `scripts/build-libavcodec.sh` builds FFmpeg
with only the H.264 decoder (LGPL 2.1, no GPL parts) as universal
dynamic libraries in `mac/MarkOne/Vendor/ffmpeg`, which the app embeds.
With low-delay mode and one thread, every frame of the one-minute capture
comes out as soon as it goes in, in 4.5 ms including the NV12 copy, and
matches PyAV's output exactly. The app credits FFmpeg, links to the
source and includes the LGPL text (see "FFmpeg and entitlements" below).

The stream follower used to search past the first access unit delimiter
after a frame for one whose header followed. When a large frame left the
next one unwritten, that search found frames left over from an earlier
lap of the ring, glued several together and lost track for a second.
Delimiters can't appear inside a frame, so now only the first one counts:
if its frame doesn't follow, the follower waits and reads again.

## Starting a recording from the computer (works)

Buttons reach the firmware as key events: 0x0200xxxx for a press,
0x0201xxxx for a release, 0x0202xxxx while held, where xxxx is the
hardware key code. The key table at 0x602a9d00 (copied from 0x7ea0c1c0)
pairs each code with a 4-letter name; the custom-function buttons are
Cut1 (0x000b), Cut2 (0x1209) and Cut3 (0x120a), and the REC button is
Cut2, 0x1209. These hardware codes differ from the shooting API's key
IDs (API_MOVIE_KEY = 11).

The key dispatcher (0x7e5ec815) passes each event to 0x7e9df69d, which
tracks keys held together (0x7e751c42), drops keys on the cancel list
(0x7e751eeb, empty in PC shooting) and posts a 12-byte message to the
key queue with 0x7e751c1b. `asm/key.s` calls 0x7e751c1b directly:
pressing and releasing 0x1209 starts a recording with USB connected, and
doing it again stops it. Mark One loads the stub at 0x7eab0380 (console
usage text for `sdk api ctrlRelease`), presses REC when Start is clicked
and again on Stop or quit. The shooting API's sequence state
(0x602b1ff4) reads 0x10 while recording and 1 when idle, which tells
whether the press worked.

Dead ends: OlyApiShootingController::ctrlRelease (`asm/release.s`) sets
up an automatic release for when a sub-screen closes; it refuses while
recording and starts nothing from idle. Posting the mode manager's movie
key event 0x01000022 (`asm/post.s`) does nothing in PC shooting.

Build the stub:

```sh
T=toolchain/install/bin
$T/mn10300-elf-as -o asm/key.o asm/key.s
$T/mn10300-elf-ld -Ttext=0x7eab0380 --defsym key_post=0x7e751c1b \
  -e key -o asm/key.elf asm/key.o
$T/mn10300-elf-objcopy -O binary asm/key.elf asm/key.bin
```

## Power switch in webcam mode (fixed)

In webcam mode the power switch did nothing. It never turned the camera
off, so sliding it back on did nothing either. Normal PC mode (MTP, no
`shoot`) turns off fine.

`ptp.py trace` shows why. It loads `asm/trace.s`, which hooks the mode
manager's two loggers (0x7edda1e3 and 0x7edda1f8, both reached by
jumps that fit in one cache line) and records each message and number in
a ring the computer can peek. The mode manager logs every state handler,
mode change request and refusal, so the trace reads like a story.

The switch reaches the mode manager in both modes, through
`notifySystemEventCallback` (0x7edd910c), which turns system event 0x27
into OLY_POWER_SW_OFF (0x01000049; 0x26 is OLY_POWER_SW_ON, 0x01000048).
The event loop (0x7edd904b) then asks `CheckEvent` (0x7edc720c) whether
the event is a mode change. Its table at 0x7eeea834 pairs
event - 0x00ffffff with a handler. Three events, 0x01000000, 0x01050001
(USB disconnected) and 0x01000049, use 0x7edc725f, which answers yes when
the app changer's state (+20) is 3. That state is the PC camera mode,
which only `shoot` reaches. A yes sends the event to `applicationChanger`
(0x7edc7281) instead of the current app. The app changer ends the app on
USB disconnect but has no case for the power switch, so it drops it.

In PC mode, and in normal shooting, the answer is no, the app's own event
list runs ("startPowerOff" in PC mode, 0x7edce234 in Shooting), and the
app requests mode change 6, power off.

The fix points the power switch's entry (0x7eeea8b0) at 0x7edc726a, the
handler that answers no. Mark One and `ptp.py shoot` write it through
the cache. Only state 3 behaves differently, so nothing else changes.
With it, the switch turns the camera off from webcam mode through the
usual path (Misc app, `executePowerOffSubAppStateMisc`), even while
recording, and the camera starts up normally when switched back on.

## Webcam controls (Mark One, 2026-11-08)

Everything here runs through the usb-tools commands while the camera is in
shooting mode; nothing is flashed. Methods take their object in a0, so
call them with `run(function, d0, d1, object, a1)`.

### Starting on demand

The camera extension publishes a custom device property
`4cc_used_glob_0000` (selector 0x75736564, a CFString "1" or "0") that
says whether any app has the Mark One camera's stream open. Mark One
reads it every quarter second while idle, starts recording when it reads
"1" (or when the panel's preview is on screen), and stops after 5
seconds of "0".

### Objects and settings

- Settings, `*(0x602b2598)`: setSetting 0x7ead1020 (d0 = id, d1 = 0,
  a1 = value), getSetting 0x7ead08aa (d0 = id, a1 = where to write the
  value). changeMode (vtable slot 88) refuses with 0xf0000058
  ("unresponsive") in PC shooting, because the release permission flag at
  0x602b1f20 is 1.
- CameraCommon, `*(0x602b243c)`: backlight 0x7eaa6ebc (d0 = 1 on at the
  dimmed level, 0 off), endSaveLcd 0x7eaa6bf6 (undim), startSaveLcd
  0x7eaa6b2c (dim), setModeDialState 0x7eaa71cd (d0 = state),
  getModeDialState 0x7eaa683f. Dial states: movie 5, S 0xb.
- setModeDialState stores an override position in the halfword at
  0x605aedbc. While it's nonzero the camera ignores the real mode dial;
  clearing the low 16 bits hands the dial back.
- Setting IDs: exposure compensation 0x03 (0x100 is +1 stop, thirds are
  0x55 and 0xab, negative values are two's complement; it works while
  recording, though the camera shows no value on screen), AF target
  0x79 (1 to 35, by columns on the 7x5 grid: 18 is the center, 31 the
  top right), movie AF mode 0x1b2 (0 single, 1 continuous, 2 manual),
  USB mode 0x76 (0xff is Auto), sleep 0x2f, auto power off 0xb2,
  backlit LCD 0xfe. 0x136 has the first six picture mode values but
  isn't the picture mode.
- More setting IDs, found by reading every setting before and after a
  change on the camera (2026-11-08):
  - White balance 0x0b: Auto 0, Sunny 6, Shade 8, Cloudy 7, Incandescent 1,
    Fluorescent 3, Underwater 18, Flash 17, One-touch 13 and 14, Custom 9.
  - Picture mode 0xac: i-Enhance 7, Vivid 0, Natural 1, Muted 2, Portrait 5,
    Monotone 3, Custom 6, e-Portrait 8, then the art filters 9-18.
  - Face priority 0x172: off 0, faces 1, then the three eye options 2-4.
  - Movie quality 0x43: Full HD Fine 0, Full HD Normal 1, HD Fine 2,
    HD Normal 3, AVI 4 and 5. The camera reads it when a recording starts.
  White balance, picture mode and face priority take effect at once in
  shooting mode.
- Every setting has a 20-byte descriptor: {u16 id, u16 flags, value
  pointer, pointer to the allowed values, u16 count × 64, ...}. The
  descriptors hang off a hash table of 128 buckets at 0x605ca034 (nodes
  {descriptor, next}). The allowed values come in the order the camera's
  menu lists them, which is how the names above were matched. Read values
  through getSetting and the read32 helper. Peeking the out word misses
  writes still in the cache.
- Battery: the standard PTP property 0x5001 (uint8, 1-100), which the
  camera lists in its device info. Its description (GetDevicePropDesc)
  claims a range of 1-100 in steps of 1, but the value is coarse: 100
  for the first 45 minutes of recording, then 50 while the camera's own
  icon flashed empty, shortly before it died (2026-11-09).
- The camera reads the movie AF mode when a recording starts. Changing
  it mid-recording does nothing until the next one, so Mark One restarts
  the recording when the setting changes.

### Keys

Key events are `0x02KKxxxx`: 0x0200 press, 0x0201 release, 0x0202 held
(sent about every 0.1 s by long-press keys). REC is 0x1209, the shutter
half press ("Trg1") 0x0100, the full press ("Trg2") 0x0101. The key name
table at 0x7ea0c1c0 is offset: each name pairs with the code six entries
later.

- The key task sends events through 0x7e9df69d (d0 = event, d1 = param,
  a0 = source). It updates the long press table at 0x605aab98 (8-byte
  entries {key, held, flag}; only REC, 0x000b, 0x120a, 0x2004, 0x2005
  and 0x2202 are in it), runs the filter 0x7e751eeb, and posts with
  key_post 0x7e751c1b. `asm/key.s` calls key_post directly, skipping the
  filter; `asm/button.s` calls 0x7e9df69d, the way a real press arrives.
- The filter drops events listed in the cancel list at 0x605aabd0 (75
  entries of {event, param}). KeyCtrl's cancelKeyEvent 0x7eacb1a9 (d0 =
  count, a1 = a list of event numbers) fills it and resetKeyEvent
  0x7eacb21a clears it. Event numbers: power 36/37, half press 44/45,
  full press 48/49, up 52/53, down 56/57, left 60/61, right 64/65, OK
  68/69, menu 72/73, play 76/77, movie 80/81, delete 84/85, info 88/89,
  Fn1 92/93, Fn2 96/97, zoom 100/101, EVF switch 120/121, main dial 125,
  sub dial 126, focus ring 127, zoom ring 128. Mark One's lock cancels
  all of these but power, the half press and the dials.
- The real shutter button sends only a press and a release, with no held
  events in between.

### Focusing from the computer

A half press focuses even while recording, but only if the camera thinks
the button is still down. The key task keeps a record of the shutter
button in four bytes at 0x60501e98. On a half press (0x7e5ec962) it sets
0x60501e99 and 0x60501e9b to 1 and sends the press event; on release it
clears them. 0x7e5ebb4b answers "is this key down" for keys 0x0100 and
0x0101 from that record instead of the hardware (as long as 0x60501e9c
is 0, which it is after startup).

While recording, a half press starts focusing; message 16107, dispatched
at 0x7ec7fd1b to 0x7eb75d93, then asks whether the half press is still
down (0x7eb70eae, through 0x7e761b28 and 0x7e5ebb4b) and stops focusing if
it isn't. With only the press event sent, the record says the button is
up, so focusing stopped after about 0.3 seconds. Setting the two bytes
before the press and clearing them after the release makes it focus like
the real button. Dead ends on the way: repeating held events, and
cancelling the release event (a cancelled release also counts as
released).

The camera doesn't say when movie autofocus has finished. The AF status
call 0x7e75a7bd stays at 16 while recording, the AF indication
0x7e68658c turns on partway through the search, and
`CapTre_TakeReady::notifyAFOK` returns early while recording. Mark One
watches the picture instead: sharpness in the middle of the frame falls
while the lens searches and settles when it has focus, about 1.2 seconds
after the press with a Panasonic 25mm f/1.4.

To check a focus change without someone watching the camera, stream with
a script, decode the frames with PyAV, and track the variance of a
Laplacian over the center 400x400 pixels. A real half press took it from
3 to 265 on an out of focus scene.

### Watching key events

To see what a button sends, hook the filter's entry (0x7e751eeb, jumping
from 0x7e751eeb over `mov d0,a3; mov d0,d3` and the first part of the
`and`, all in one cache line) and the start of key_post, and record
{event, param, caller} in a ring that a peek reads, like `asm/trace.s`.
Callers 0x7e9df6ae and 0x7e9df6bd are the key task; 0x7e761b48 is
0x7e761b28, which code uses to ask whether an event would get through.

Build the button stub:

```sh
T=toolchain/install/bin
$T/mn10300-elf-as -o asm/button.o asm/button.s
$T/mn10300-elf-ld -Ttext=0x7eaaf5e0 --defsym key_task_send=0x7e9df69d \
  -e button -o asm/button.elf asm/button.o
$T/mn10300-elf-objcopy -O binary asm/button.elf asm/button.bin
```

## Webcam USB choice (working)

Flashed 2026-11-08 at version 2.3. Custom menu > USB Mode lists Webcam
after MTP, the USB prompt lists Storage, MTP, Webcam, Print, Exit, and
choosing Webcam connects like MTP with 0x605f0d14 reading 7.


The `webcam` patch set in `scripts/build.py` adds a "Webcam" choice to the
camera's USB prompt (Storage, MTP, Webcam, Print, Exit) and to Custom
menu > USB Mode and bakes in Mark One's run-time helpers. `version=X.Y`
sets the version the camera reports. Build it on top of usb-tools:

```sh
uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN \
  patched/usb-tools+webcam/E0972300.BIN usb-tools webcam
```

How a USB connection picks its type: the type lives at 0x605f0d14.
With USB Mode on Auto the prompt (built at 0x7eec6dab, OK handled at
0x7eec70d7) sends a GUI param to checkEndUsbSelect (0x7edd5b9b), which maps
15, 16 and 17 to Storage (1), MTP (2) and Print (4). Otherwise 0x7edd54f6
maps the USB Mode setting (118) to a type. checkPcMode (0x7edd59ea) sends
types 1 and 2 to startPc, whose protocol choice at 0x7edd5564 picks MTP
for type 2 and mass storage for the rest. completedPcConnect gives type 2
PC sub-state 0x6005 and everything else 0x6004. No other code compares
the type with 2.

Webcam is a new type 7. The prompt sends GUI param 20 for it,
checkEndUsbSelect and the USB Mode mapping turn 20 and setting value 7
into type 7, and the protocol choice now picks mass storage only for type
1. Type 7 lands in sub-state 0x6004, whose event list already includes
the "start camera control" events, so the run-time 0x6005 table write
isn't needed for it. The computer can tell Webcam from MTP by reading
0x605f0d14.

- The prompt's list (`asm/webcam/prompt.s`), OK button
  (`asm/webcam/ok.s`), checkEndUsbSelect (`asm/webcam/select.s`) and the
  USB Mode mapping (`asm/webcam/mode.s`) are rewritten in place as table
  lookups. The prompt also writes 5 to screen 0's cursor wrap count, the
  halfword at 0x602bceb0, which has no static writer.
- The USB Mode option records at 0x7f00ab30 (28 bytes each) run straight
  into the next list's, so the five records go over console-only code at
  0x7eaaf680 and the list header at 0x7f00c63c points there. Unknown:
  whether the settings code accepts 7 for setting 118.
- The label is string 0x3fd ("A. OLYMPUS PENPAL Share", shown only for
  the PENPAL accessory), rewritten to "Webcam" in all 34 languages of the
  resource block (0101). Each language region in that block has a table
  of 1695 pointers to UTF-16 strings, relative to 0xbff3d020; region 8 is
  English. This is the first image that changes block 0101.
- Version: the main block head's version word (0x10, `00 23`) sets the
  displayed version (setting 0xc082) at boot; the body version that
  GetVersions (0x9120) reports has a hardcoded 0x2300 at 0x7f0dd970. The card updater won't install a
  lower version than the one on the camera: `patched/version-test`
  (usb-tools with version 1.0 and nothing else) went to a fast-flashing
  light with no solid phase, and the camera stayed on 2.3 (2026-11-08).
  The webcam image at 1.0 was refused the same way, both as
  `E0972300.BIN` and renamed to `E0971000.BIN`, so the file name isn't
  what it checks. The updater reads the version word at file offset 0x10
  (the main block head) and compares it with the installed version.
  Equal versions pass, so never build above 2.3: a camera on 2.4 would
  refuse stock 2.3 and have no way back.
  Same-version images install fine, so build at 2.3 and use the stock 2.3
  image on the card to go back.

Build the patches:

```sh
T=toolchain/install/bin
for f in prompt:0x7eec6dfb ok:0x7eec7101 select:0x7edd5bb2 mode:0x7edd54ff; do
  n=${f%%:*}; $T/mn10300-elf-as -o asm/webcam/$n.o asm/webcam/$n.s
done
$T/mn10300-elf-ld -Ttext=0x7eec6dfb -e prompt --defsym set_screen=0x7eec7262 \
  --defsym done=0x7eec6f49 -o asm/webcam/prompt.elf asm/webcam/prompt.o
$T/mn10300-elf-ld -Ttext=0x7eec7101 -e ok --defsym exit_path=0x7eec7126 \
  --defsym send=0x7eec7169 -o asm/webcam/ok.elf asm/webcam/ok.o
$T/mn10300-elf-ld -Ttext=0x7edd5bb2 -e select -o asm/webcam/select.elf asm/webcam/select.o
$T/mn10300-elf-ld -Ttext=0x7edd54ff -e mode --defsym resume=0x7edd5535 \
  -o asm/webcam/mode.elf asm/webcam/mode.o
for n in prompt ok select mode; do
  $T/mn10300-elf-objcopy -O binary asm/webcam/$n.elf asm/webcam/$n.bin
done
```

## Unplugging in webcam mode (fixed, 2026-11-09)

Found with `scripts/unplug.py`, which posts the unplug event (system
event 9) to the system event callback with the cable still in. Its
context is 0x60010e44 (vtable 0x7ef013f4, beside the event table at
0x7ef013fc); `--find-only` finds it next to the callback in RAM.

- Not recording: the event goes through CheckEvent to
  applicationChanger (event 0x8000005, info 0x6000002), SEND_END_APP
  ends the PC app's sub-app and mode change 6 follows. With the cable in,
  the camera goes back to its USB menu, but Mark One's key cancel list is
  still in place there, so the arrows and OK do nothing (the control dial
  still moves the selection).
- Recording: the shooting app drops the event. Nothing else happens, and
  stopping the recording afterwards doesn't bring it back. So a real
  unplug mid-call leaves the camera recording, with the buttons locked and
  the mode dial forced to movie: the stuck camera.

Fix (`asm/unplug.s`, built into revision 4 of the firmware; before
that, loaded by Mark One's `prepare` and by `scripts/unplug.py --fix`):
the callback's first two instructions become a
jump to a stub at 0x7eaaf600. For event 9 it clears the dial state in the
override, calls resetKeyEvent and, if a movie is recording, presses and
releases REC through the key stub; then it runs the replaced instructions
and carries on at 0x7edd9111. Posted mid-recording with the fix, the
camera stopped recording, dropped off USB and came back with its buttons
and dial working. Checked with a real unplug mid-call (2026-11-09): the
camera recovers, and plugged back in it connects and streams normally.

Revision 4 (2026-11-11) builds the stub and the callback jump into the
firmware, so Mark One writes no code into the camera's memory on revision
4: `prepare` checks the jump is there and sends the "start camera
control" notification, and nothing else. The helpers, key and button
stubs and the power switch entry were already built in from revision 1,
and the 0x6005 event list write isn't needed for the Webcam connection.
The hook is now there from boot in every mode, not only after a Mark One
session. The stub only acts on event 9, and outside a session its work
should change nothing (no keys are cancelled and no movie records over
USB; it clears the dial override's state half, as releasePresets does).
To check: plug in as Storage and MTP, unplug, and the dial and buttons
still work. Still loaded at run time: the
install restart (`asm/restart.s`), which only the install over USB uses.

### A message after unplugging (in progress, 2026-11-16)

After an unplug mid-call the screen stays dark for up to 10 s before the
camera goes back to normal. The aim is to show "One Moment" over that gap.

- The GUI's warnings are a table of 46 records, 20 bytes each, at
  0x7ef0af60: byte 0 the index, byte 1 the style, halfword 2 an icon,
  halfword 8 the string ID. 0x11 is "One Moment" (string 0x39a, no icon),
  0x24 "Remove USB Cable" (0x3b6). 0x1a-0x1c, 0x26, 0x27, 0x2d and 0x2e
  are empty, if another message is ever needed.
- setDbWarningInfo (0x7edf38fc) shows one: a0 = the GUI's common object
  (0x7edf3876 returns it), d0 = index, d1 = 1. It runs in the GUI task and
  has no prologue of its own (the frame comes from `call [d2,d3,a2,a3],16`).
- How Exit shows its message: the prompt's OK handler stores 36 (0x24)
  at 0x602bceaf (0x7eec7379); checkPcMode (0x7edd59ea) posts 0x09000010,
  SUB_EVENT_START_WAIT_USB_DISCONNECT (names at 0x7ef04714); its handler,
  startWaitUsbDisconnect (0x7edd5b6f), makes request 135 with param 36,
  and the USB GUI (0x7eeae6e2) passes the index at 0x602bceaf to
  setDbWarningInfo.
- `asm/wait.s` calls it from `run`, loaded at 0x7eaafa70 in the free end
  of the `sdk api` dump after `asm/nocard.s` (free to 0x7eaafbb3).

To try on the camera, with Mark One quit:

1. In MTP: `ptp.py poke 0x7eaafa70 asm/wait.bin`, then `ptp.py run
   0x7eaafa70 0x11`. Does "One Moment" show, and does `run ... 0` clear it?
2. In a session (`ptp.py shoot`, recording): the same. This is the screen
   the unplug stub would draw over.
3. With `scripts/unplug.py --fix`, call it from the unplug stub (or right
   after posting the event) and watch whether it stays up through the gap,
   or the app change clears it. If it's cleared, it has to be shown again
   later in the hand-off.
4. Calling the GUI from the system event callback's task is untested;
   watch for hangs.

### Before the fix (2026-11-08)

Unplugging the cable while Mark One uses the camera leaves it stuck: it
keeps showing movie mode, the mode dial and buttons do nothing, and only
a battery pull recovers it. Plugging a stuck camera back in freezes it
(black screen with the shooting info on it, no USB). Mark One's own
cleanup (stop recording, `releasePresets`) can't run once USB is gone.
Mark One now keeps the camera's own settings on the Mac until they're
back on it (`Firmware.Saved.pending`), so they survive this.

What the code shows (read in main.s, not yet traced on the camera):

- Unplugging is system event 9, which `notifySystemEventCallback`
  (0x7edd910c, table at 0x7ef013fc) turns into 0x01050001 for the mode
  manager. `CheckEvent`'s entry for it, at 0x7eeea89c, is
  {0x00050002, 0x7edc725f}, the same "yes while the app changer's state
  is 3" handler the power switch had. State 3 is the PC camera mode only
  `shoot` reaches, so in webcam mode the event goes to
  `applicationChanger` (0x7edc7281). It rewrites it to PC_RETURN
  (0x08000007) and sends MNG_END_CAM to the camera app, which has to end
  the shooting sub-app before CHANGE_APP restarts the PC app. That
  hand-off seems never to finish while a movie records. Stock never
  reaches state 3 here, so this path is new.
- In stock PC mode (Storage or MTP, no `shoot`) unplugging turns the
  camera off: the PC app's common list maps 0x01050001 to 0x7edd5900
  ("UsbDisconnectSubAppStatePc"), which calls "startPowerOff".
- The dial override (0x605aedbc) and the key cancel list (0x605aabd0)
  are plain RAM, so they stay set however the hand-off ends.

Tried: the power switch's fix applied to unplugging, writing 0x7edc726a
("not an app change") to 0x7eeea8a0 so the event goes to the shooting
app's handler (0x7edce234: 0x7edcc367, then mode change 6, power off).
The recording stopped but the camera didn't turn off; it stayed in movie
mode with the dial dead. Clearing the low half of 0x605aedbc and calling
resetKeyEvent over USB afterwards didn't bring it back either, so
something else is stuck, perhaps mode change 6 being refused. Mark One
doesn't make this change.

Next:

1. Trace it without pulling the cable: `scripts/unplug.py` (ready, not
   yet run). It sets the camera up as Mark One does (shooting, movie
   dial, locked controls, recording), starts the trace logger, calls
   0x7edd910c with d1 = 9 and a0 = the mode manager object it was
   registered with, and prints the log. That object is `(52,a0)` of the
   app changer (fn_7edd8fd1, from 0x7edc71ff); the app changer is
   temporary and nothing keeps a pointer to it, so `--find-only` searches
   RAM (0x60000000-0x60800000) for the registered callback and shows the
   words around it, and `--context` takes the one to use. The callback
   builds its own frame (`movm`, `add -28,sp`), so `run` can call it. A
   real unplug leaves nothing to read, since the camera drops off USB and
   a battery pull clears RAM.
2. From the trace, find where it stops: the shooting sub-app's end, mode
   change 6 refused (the release permission flag at 0x602b1f20 is 1 in PC
   shooting; see "Objects and settings"), or something else.
3. Likely fix: a small stub on the unplug path (in `prepare`, like the key
   and button stubs) that clears the dial override, resets the cancelled
   keys and then lets the camera turn off, the way stock PC mode does.
   A draft that does the first two and answers "no", for 0x7eaaf600
   (free console usage text up to 0x7eaaf680, clear of what Mark One
   uses), linked with `--defsym reset_keys=0x7eacb21a --defsym
   answer_no=0x7edc726a`:
   `mov (20,a0),d0; cmp 3,d0; bne done; mov a0,a2; add -8,sp;
   mov (0x605aedbc),d0; and 0xffff0000,d0; mov d0,(0x605aedbc);
   calls reset_keys; add 8,sp; mov a2,a0; done: jmp answer_no`.
   `ptp.py trace` keeps its ring at 0x7eab041c-0x7eab04a0, after the
   firmup stub and revision marker. Its first version used 0x7eab03e0,
   256 bytes, which overwrote both in RAM, so MTP's command setup would
   have jumped into ring data on the next connection.

## Installing firmware over USB (recorded, 2026-11-08)

Goal: Mark One installs the webcam firmware itself, with no SD card.

### How the update was recorded

OM Workspace only offers an update to a camera that reports an older
version, and it reads the version with GetVersions (0x9120). That
handler builds the body version string (`OLYE0970000000000-00002300-…`)
from the `mov 0x2300,d2` at 0x7f0dd970, not from the block head. With
usb-tools in MTP mode, writing `00 10` at 0x7e421010 and `10 f2` at
0x7f0dd972 makes the camera report 1.0 until it restarts. The camera
was then moved, still on, to a Windows PC in Storage mode, where OM
Workspace offered 2.3 and installed it. USBPcap recorded the session;
the recording is `captures/om-workspace-update-2.3.pcap` (gitignored,
135 MB, the camera is device 13).

### Transport

In Storage mode (USB product ID 0x012e) the PTP containers travel inside
vendor SCSI commands on the mass storage bulk pipes. Each CDB is 16
bytes, with the transfer length at bytes 9-12 big-endian:

| CDB | Direction | Carries |
| --- | --- | --- |
| c0 | out, 64 bytes | the command container |
| c1 | out | a data container (12-byte header, then data) |
| c4 | in, 64 bytes | the coming data phase's header (its length) |
| c2 | in | a data container |
| c3 | in, 64 bytes | the response container |

macOS gives mass storage devices to its own driver, which is why OM
Workspace needs a kernel extension there.

### The update, as OM Workspace runs it

1. OpenSession, GetFirmwareUpdateMode (0x911c, answers 1), GetVersions
   (0x9120, body then lens), GetLanguageCode (0x9124 with 1, then
   0x8000), CloseSession. Then OpenSession again once the user starts
   the update.
2. 0x911c again (answers 1).
3. SendFirmDataInfo (0x9125, param 0x80000001) with 60 bytes of data:
   words 0x80000001, 0xb001, the file size (0x02c70000), then zeros.
   Response params 0x80000001, 0, 0xfffffff9.
4. SendObjectSplit (0x9119, params offset and length) 734 times, 0xf800
   bytes each and 0xe800 for the last, about 5 s in all. The pieces are
   the stock `.BIN` file unchanged (sha256 cb158dbd…).
5. FirmwareCheck (0x9121).
6. 0x9122 once a second. It answers (1, 0) while the camera checks the
   file and (2, 0) when it's ready, about 30 s later.
7. UpdateInitiate (0x9123). The camera then installs on its own and
   shows "OK".

The camera's own version check (same version or newer) applies here too.

### Doing it from Mark One (working, 2026-11-08)

The firmup commands are registered only for connection modes 0 and 5,
not MTP (mode 4). The dispatcher looks 0x9xxx commands up in the
registered list only (0x7f0d9fcd, else 0x2005), so registering them is
enough. In the webcam patch, MTP's setup (0x7f0d4a5b) ends with a jump
to `asm/firmup.s` at 0x7eab0400 instead of its last `call register` and
`ret [],4`. The stub makes that registration, calls the update block of
modes 0 and 5's setup (0x7f0d49a4, which ends `ret [a2],8`), and returns
for the setup function.

The webcam patch also writes "MARK" and a revision number
(`WEBCAM_REVISION` in `scripts/build.py`) at 0x7eab0414. Mark One reads
it: a camera that refuses the read (0x2005) has stock firmware, one
without the marker has a build from before revisions (0).

`scripts/ptp.py versions` sends 0x911c and 0x9120, and `ptp.py update
FILE` runs the whole sequence over MTP.

Tested on the camera: `ptp.py update` reinstalled revision 1 over MTP,
on a camera freshly switched on (not in Mark One's shooting setup). The
status poll answered (1, 0) for about 30 s, then (2, 0), and 0x9123
started the install. The camera showed its update animation, then OK;
switched off and on, it reported revision 1. Installs mid-session, after
Mark One's setup, work too (see the end of this section).

Connected as Webcam (type 7), 0x911c and 0x9120 answer the same as over
MTP, so the webcam connection gets the update commands too.

Mark One's setup:

- A stock camera gets its first install from the card. Mark One
  downloads stock 2.3 from Olympus's server, checks its hash, applies its
  changes as byte edits (`mac/MarkOne/App/Resources/webcam-firmware.json`,
  from `scripts/build.py --edits`, so the app ships no Olympus code),
  writes `DCOLYMP/E0972300.BIN` to the card and ejects it, then shows the
  steps on the camera. Mark One isn't sandboxed (it's distributed directly,
  not through the App Store), so it writes to the card it finds; macOS asks
  once whether it may use removable volumes.
- A camera with an older revision gets the update over USB, after Mark
  One stops recording.

Firmware comes from a POST of `<firmware_demand>` XML to
`https://fw01.om-digitalsolutions.net/ww_inform/fcache.do`, documented
for the E-M10 in github.com/matozoid/em10_1
(`docs/firmware/update-server.md`); not tried for E-097. The same
project's decompile of OM Workspace's Windows library matches the
recorded sequence.

Since 2025-12-20, Olympus firmware can't be downloaded directly, only
by asking the update server the way OM Workspace does. The community
firmware list kept by a mu-43.com member
([spreadsheet](https://docs.google.com/spreadsheets/d/10vaBZZrfVLeotlAjfGy5Vo_qtelXevRkdPMBd-VN53k/edit))
says so, and points to a shell script in the
[mu-43.com firmware thread](https://www.mu-43.com/threads/firmware-updates-for-om-and-em-cameras-january-2023.118773/page-6#post-1837553)
that asks the server for a signed link to the file on Olympus's servers
(`dl01.om-digitalsolutions.net`). Mark One's download works the same way.

A USB install works on a camera Mark One has set up (2026-11-09):
shooting mode, movie dial, a recording started and stopped, keys reset.
The check took about 43 s instead of 30. While it installs,
the screen flickers between the update icons and the last live view
frame left in the display buffers; the install itself is fine. The app
now installs straight away instead of asking for a restart.

## Recording time limit

Tested 2026-11-09: with only the 'time limit' patch below, a webcam session
stopped at exactly 30:00, and the camera then showed live view but ignored
REC (from Mark One and the camera's own button) until it was switched off.

0x7e7bbe71 works out how long a movie may run and logs "MAX Time" (what
the card's free space allows, d3) and "Limte Time" (d2, the limit),
stored in frames at +32 and +40 of the recorder's state. The format
maximum is 1740 s for MOV Full HD and HD (`mov 1740,a3` at 0x7e7bbf89),
7200 s for SD, and the limit is the smaller of that and the card figure.
`ptp.py shoot` now raises the maximum to 32767 s and uses it for both
values (RUNTIME_PATCHES 'time limit'). Also unknown is what the
QuickTime writer does at 4 GB ("[QT] AVSCA_INF_DIV_FILESIZE" and
"REC_FILESIZE" are only logged at 0x7e7a85ee/0x7e7a85fc), which the
muxer would reach after about 27 minutes at 20 Mbps even with card
writes skipped.

The second limit is the QuickTime muxer's (found in the code, not yet
confirmed on the camera):

- rec_init (`MovmidApi_cmd_rec_init`) builds the muxer's parameters at
  every recording start (fn_7e7a7b8e). `0x7e7a7c51: mov 1800000,d0` sets
  ulMaxRecTime (labelled at 0x7e7a8ae0) to 1,800,000 ms for qualities 3, 5
  and 6 (Full HD and HD); SD gets 7,200,000 ms (0x7e7a7c59). It lands at
  0x6072fc00. In stock firmware the 1740 s app limit fires first, so the
  muxer's own stop is never used.
- The same block has ulUpper 0 and ulLower 0xFFFFFFFF, probably a 64-bit
  maximum file size of 4 GiB - 1. Full HD Fine is 20 Mbps video plus
  1.536 Mbps PCM audio, about 26.6 minutes to 4 GiB. Today's run passed
  30 minutes, so either the stream averaged under about 19 Mbps or the size
  doesn't stop recording. Unconfirmed.
- When the muxer stops itself, InputVideo "Term" (0x7e7a873d) sets
  0x6072fe10 = 1 and every later frame is dropped. The recorder's stop
  (user_stop, 0x7e7bc330) then sends RECORD_END and waits with no timeout
  (0x7e7bc930, 0x7e7bc9d0). Likely chain: AVSCA_Stop fails on the stopped
  muxer, "[QT] REC STOP Error" makes the MOV_AVCHD task exit (0x7e79e521),
  the recorder waits forever, and the shooting app stays in SEQ 18
  (0x7ec800a5), which ignores REC. No runtime way out found; switch the
  camera off.

Fix (2026-11-09): RUNTIME_PATCHES 'muxer time limit' (0x7E7A7C50) uses the
SD value, 2 hours. Larger values are untested: the muxer seems to multiply
by 90 (a 90 kHz clock), and anything over about 6.6 hours would overflow
32 bits. Mark One also stops and restarts the recording itself after 100
minutes, through the normal stop, and logs the size and bitrate. It used
to restart at 3.5 GB too, in case of a 4 GB file limit, but there isn't
one: on revision 4 with a card in, a recording ran past 4.6 GB and 37
minutes, until the battery ran out (2026-11-11).

Peeks for a stuck camera (uncached): SEQ at 0xA02B1FF4 (18 = stuck),
MOV_REC state {function, number} at 0xA05B5C7C (0x7e7bc330/6 = waiting in
user_stop), muxer stopped flag 0xA072FE10, the parameter block at
0xA072FBC0 (0x44 bytes), and the trace ring at 0xA0784E4C (u16 oldest, u16
next, then 64 entries of {u8 category, 3 pad, u32 value} at 0xA0784E54).
After unplugging and replugging USB they all read 0, so the stuck state
wasn't captured.

The camera won't record without a card (tested 2026-11-09). With none, it
lists one storage ID, 0x00010000 (PTP "no media"), and GetStorageInfo on
it answers 0x2008. Mark One checks for this before setting up and asks
for a card.

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

## Recording without a card (revision 2, working 2026-11-09)

Revision 2 of Mark One's firmware (`asm/nocard.s`, in build.py's `webcam`
patches) records in webcam mode with no card, never creates a movie file,
and lifts the time limits, all only while the connection type
(0x605f0d14) is 7. It stays 7 in shooting mode with USB connected. With
a card in, nothing is written: no new P101xxxx.MOV after hooked sessions.

Thirteen hooks, each a 5-byte jump (plus nops) to a stub over the
console-only `sdk api` EV_* dump at 0x7eaaf760 (780 bytes; free to
0x7eaafbb3). Outside webcam mode each stub runs the instruction it
replaced. See the header of `asm/nocard.s` for the list. What it took:

- REC with no card is refused silently by the shooting app's movie start
  check (movie_record_start, 0x7eb7185e, line 7910): the media state for
  movies (0x7ea7fcd1 with d0 = 4) is 0x1001 with no card and must be
  0xf000. S13 reports 0xf000 to that check only. Every refusal there goes
  through the logger 0x7eb6b884 (d0 = line, a1 = tag); `asm/refusal.s`
  records them, which is how line 7910 was found.
- The recorder needs a nonzero limit (S1 sets +32/+36/+40 of its state),
  no TIME_LIMIT check (S2) and the muxer's 2-hour maximum (S3).
- QuickTime file task commands (open, seek, tell, read) are faked as an
  empty file would answer. Each fake must clear the busy flag at
  0xa0785940 (0x7e7a62d9): the requester waits for it.
- IMDF 50 (0x7e7a792e) reserves the file number through a synchronous
  file-dispatcher call (0x7e7ac1eb). Besides creating the file entry on
  the card, it fills in the recorder's +172/+176 (0x40210000) and points
  +180 at the movie's file entry (name P101xxxx MOV, pointing to the
  100OLYMP folder entry), and writes the path to 0x605b52dc. The muxer's
  start (MOV_AVCHD command 2, AVSCA start 0x7e5497ed) reads +180 and
  crashes on a null one, which is what +180 is after a restart until the
  first real reservation. S9 skips the call and fills these in from
  stand-ins copied from a real reservation.
- MOV_FILE's open and write (S4), record_end (S10), cancel (S11) and
  QT remove (S12) are skipped.

Testing hooks at run time:

- RAM, code included, survives switching the camera off; only a crash
  (or a battery pull) reloads the firmware. Old hooks from an earlier
  session stay live, so restore them before overwriting the code they
  jump to.
- The CPU keeps stale code in its instruction cache. Code poked over
  code that has already run (a probe, then new stubs in the same place)
  crashed the camera. Hook only code that hasn't run since the CPU last
  reset (switching off and on resets it), and don't reuse space.
- The first REC key press after setting up is often ignored; press again.
- A crash shows up as the camera dropping off USB and returning to the
  USB menu.

Mark One's firmware is built from `usb-tools` and `webcam` together:
`scripts/build.py --edits mac/MarkOne/App/Resources/webcam-firmware.json
fw/OLY_E_097_2300_0000_0000.BIN patched/E0972300.BIN usb-tools webcam`.
A first revision 2 built from `webcam` alone installed fine but left the
camera without peek/poke/run, so Mark One saw it as stock; the card
install (Set Up Camera) put the right one on. Check a new build against
the last: rebuilding the previous revision with the old build.py should
reproduce the shipped edits exactly.

After a USB install the camera goes back to the picture it showed, still
running the old firmware from RAM, until it's switched off and on. Mark
One now restarts it instead (see "Restarting after a USB install").

## Restarting after a USB install (2026-11-10)

What a stock install does at the end (found by a research pass over the
code): the firmup task's USB branch (`[firmup]TYPE_FIRMUP_USBUP`,
0x7e624260) writes flash, logs `SUCCESS_REBOOT` or `ERROR_REBOOT`, draws
OK or NG, then calls fn_7e9df2e9 ("Owariyade"), which busy-waits for the
power switch to change, then powers off through the PMU (fn_7e454a2b)
and spins. Despite the log text, nothing restarts. The camera drops off
USB within a second of UpdateInitiate (0x9123), so Mark One can't send
anything after the install.

The watchdog does restart it. Boot turns it on (0x7e46789b: 0x6041e72c =
1, period 10 s) and a task feeds it every 3 s. The firmware forces a
restart itself when its second CPU doesn't answer at boot (0x7e5e53e6):
`0x7e4431bf(1)` masks interrupts, `0x40064e17(1)` sets a 1 s period, then
it spins. The console's `wdt rbt2` command does the same with the 10 s
period: calling its handler (0x7e467916, a0 = argv with argv[2] = the
firmware's "rbt2" string at 0x7e4c5939) over USB froze the camera for a
few seconds, then it came back at the USB prompt with RAM reloaded
(Mark One's hooks gone).

`asm/restart.s` is the boot-time sequence. Before 0x9123, Mark One
(`Firmware.armRestart`) checks the watchdog is on and that fn_7e9df2e9
holds the stock bytes, then writes the stub over it through the
uncached mirror. fn_7e9df2e9 hasn't run since the CPU last reset, and
only the end of an install calls it (0x7e753168
"api_firmup_Firmup_Client_END", 0x7e9df18d, 0x7e9df2e1). Tested: a USB
install of revision 3 showed OK, and about a second later the camera
restarted by itself into revision 3, with fn_7e9df2e9 stock again. The
flag at 0x6051204c turns nonzero once flash is written, but USB is gone by
then.

Settings: the camera saves settings only when it's switched off. USB
Mode set to Auto, then a watchdog restart, came back as Webcam; set to
Webcam, then switched off and on, it stayed Webcam. So a restart drops
settings changed since the last power-off.

## USB Mode Webcam (2026-11-10)

Setting 0x76 (USB Mode) to 7 makes the camera connect as Webcam without
asking. Mark One sets it while "Connect as a webcam without asking" is on
(the default), and sets Auto (0xff) when it's off. Stock firmware maps
setting values it doesn't know to Storage (0x7edd54f6: 0xff Auto, 4 and
5 MTP, 3 and 2 their own types, everything else Storage), so a camera
restored to Olympus's firmware with USB Mode still Webcam connects as a
drive. Before restoring, Mark One sets Auto and has the camera switched
off and on, so it's saved, then carries on.

## Video pauses (in progress, 2026-11-09)

Mark One's stream pauses for 0.2-1.4 s, then the frames arrive at once:
the camera keeps encoding while Mark One can't find the next frame. The
logs ("No video from the camera", "Slow pass", "Lost track",
"frames failed to decode") show it's the frame finding in
`Streamer.swift`, not USB: during a pause the polls are fast and empty.

- Fixed: the last frame before the encoder wraps to the start of the
  ring (every 1-2 s) is followed by older data with no delimiter, so Mark
  One waited half a second for the recorder's table. It now ends that
  frame by comparing with a shadow copy of the ring (`wrapLength`). That
  took a 22-minute session from 15-25 pauses a minute to about 4, but
  about a third of those guesses are off (frames that fail to decode,
  about 8 a minute).
- Each picture is one slice (AUD, SPS at keyframes, PPS, SEI, slice);
  P-frames run 50-80 KB, keyframes about 170 KB. The bytes after a slice
  hold no start codes, so slice parsing can't find the end.
- Still open: "Lost track" (no frame for a second, then resync at a
  keyframe), about 3 a minute in a 26-minute session: 60 after a frame
  whose end came from the recorder's table, 28 after a wrap frame. Many
  of the wrap cases find the same bytes where the next frame should be
  (58ce330c0136c541...), and some wrap frames are logged well away from
  the end of the ring, which doesn't fit how they're found yet.
- Tried and reverted: always checking the start of the ring for the next
  frame (not only within 1 MB of the end). It matched stale frames and
  lost track every few seconds.
- A 56-second QuickTime clip of the result was frozen 11% of the time
  (27 freezes of 0.1 s or more, the longest 0.9 s): lost track about
  every 10-15 s, plus single-frame decode failures that break the frames
  that refer to them until the next keyframe.

### Exact frame boundaries (revision 3, tested in RAM 2026-11-09)

Why the recorder's table lags: its entries are the Video Encode plug-in's
sample objects (60 of 244 bytes, made with `new[]` at 0x7e5269a5; table
+4 is object +80), written through the CPU cache. USB reads RAM directly,
so each entry shows up only when its cache line happens to be written
back. Reading the same entries through the cache (read32) while recording
gave newer frame numbers and final sizes where the uncached view still
had old frames or the placeholder: 249 of 506 reads differed in 10 s. The
table's size (object +28) is the frame's byte count plus 1, rounded to
the buffer alignment, so table-sized frames carry one extra byte, and the
next frame starts a byte after the previous one ends.

Where a frame becomes final: the plug-in's event handler (fn_7e5304c6, in
its task, once per video frame, never for audio) asks the encoder for the
result (bytes at (24,sp), offset at (28,sp)), then at 0x7e5307b9 calls
0x7e5277ea, a leaf that stores the offset at object +96, the byte count at
+100 and 1 at +104. The buffer address is at +88 (uncached, 0xa52b...), the
90 kHz timestamp at +24. The encoder's done callback (0x7e530fc7) only
posts event 0x0b000001; the hardware's result registers are at
0x99404000-0x99404010 (not read: side effects unknown).

`asm/frames.s` replaces that call with a jump to a stub over console-only
`sdk api` commands (getDisplayDeviceState from 0x7eaaab8e; it and the
commands after it, to 0x7eaab024, are pointed to only from the console's
command table at 0x7ecda9f8). The stub does the leaf's stores and, in
webcam mode, adds {address, bytes, timestamp, number} to a 64-entry list
at 0x7eaaac10 with a count at 0x7eaaac00, written through the uncached
mirror so USB sees it at once. Number is written last; an entry is valid
when its number is the one expected.

Tested by poking it into RAM after a power cycle (revision 2 camera,
before recording): 29.92 frames/s, every listed frame starts with a
delimiter, timestamps 3003 apart. A 20-second capture copied by the list
alone: 599 frames, none missed, and from the first keyframe on 585 frames
decode with no errors under `-err_detect +crccheck+bitstream+buffer+explode`.

Mark One on revision 3 reads the list (`Streamer.pollList`), skips to the
newest frame if it falls 30 frames behind (the ring holds about 45), and
starts at a keyframe. Older revisions keep the stream follower.

Installed over USB and tested 2026-11-10: a 71-minute QuickTime
recording at 720p, 129,346 frames. Mark One logged no gaps, no skips, no
bad entries and one decode error, besides the restarts. On revision 2 a
56-second clip had 27 freezes. Scanning the file for frozen picture
(ffmpeg `freezedetect`, 0.3 s or more) found only:

- the two scheduled restarts at 3.5 GB (33.0 minutes at 15.2 Mbps, then
  30.7 minutes at 16.3 Mbps). Each froze the picture for about 4.9 s,
  almost all of it the recording check (about 4.8 s) waiting for the
  camera to say it's recording again. Then the queued frames (17 and
  18) arrive at once. The one decode error came 2 s after the second
  restart.
- one 0.43 s hitch at 52:46. Mark One logs any gap over 0.2 s from the
  camera and logged nothing then, so frames reached Mark One on time;
  the hitch was between the camera extension and QuickTime.

### Apple's decoder on exact frames (2026-11-10)

With frames cut by revision 3's list, VideoToolbox's hardware decoder
decodes the 20-second capture (585 frames from the first keyframe)
with no errors, in 0.74 ms a frame (p95 2.9 ms), and its pictures are
byte-for-byte identical to libavcodec's. Two things had broken it:

- One extra byte per frame. The recorder's table size is the byte count
  plus 1, so frames cut by it carried the byte after the frame. Adding
  0x00 after every frame still decodes; 0x80 or 0xff makes the hardware
  reject all 585 (-12909), which is what was seen before.
- New PPSs between keyframes. Every frame carries its PPS, and the
  encoder adds new ones mid-stream (IDs 1, then 0 at frame 320 when
  the frame size jumped from 23 KB to 83 KB, then 2 at frame 344); IDs
  are not reused with new contents. A session made with only the PPSs
  seen so far rejects the first frame using a new one, then everything
  until it's recreated at the next keyframe: the "1 in 100" failures.
  Making a new format description with all PPSs seen so far and
  attaching it to the following samples fixes it for the hardware
  decoder (`VTDecompressionSessionCanAcceptFormatDescription` says yes,
  no new session needed). The software decoder still rejects from that
  frame until the next keyframe.

Test: `vt.swift` (scratchpad, not kept), feeding each frame as AVCC
with a 4-byte length, hardware required
(`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`).

Mark One uses it on revision 3 (`HardwareDecoder.swift`, 2026-11-10):
it hands over to libavcodec if the Mac has no H.264 hardware decoder or
after 5 failures (about 2 s of frozen picture, tested by adding 0xff
after every frame). Same capture: 585 pictures identical to libavcodec's.
Streaming to QuickTime, Mark One went from 37-41% of a core to about
12%; what's left is mostly reading frames over USB. Finding start
codes with a byte loop in Swift was most of the cost in the Debug build;
`memmem` fixed it.

Stutter with the panel open: QuickTime's recording repeated 2-5
pictures a second while Mark One's panel was open, though Mark One's
preview was smooth and Mark One handed every frame over on time
(pauses under 55 ms). QuickTime's log ("getting frames too slowly")
showed about 10 frames a second arriving 70 ms after the one before,
only while the panel was open; the extension repeats the last frame
after 66 ms without one. The preview was showing the same pixel buffer
that went to the extension. Giving the preview its own copy fixed it:
6 frames late in the next recording, none over 36 ms. Mark One also
holds back a frame that arrives while the extension's one-frame queue
is full, instead of dropping it, and logs any frames it does drop.

## Where it stands

Mark One works end to end over USB: firmware setup from the card, updates
and restores over USB, and 1080p video from the movie recorder. HDMI
through a capture card is no longer the plan; the hdmi-liveview patch
stays here for reference, untested. What's left is in `TODO.md`.

## CPU use (2026-11-10)

Measured with `top` on an M2, 100% = one core, QuickTime recording 720p.

The extension asked Mark One for a frame (consumeSampleBuffer, a round
trip between the processes) as soon as it had one, and every 5 ms while
none was waiting: about 200 asks a second for 30 frames, and the same
while no app used the camera, because Mark One keeps the sink open
whenever the camera is connected. Most of the cost was kernel time
(the extension had spent 80 minutes in the kernel and 35 in its own
code). Now it asks 26 ms after each frame, then every 4 ms, and only
while an app is using the camera.

| | Before | After |
|---|---|---|
| Extension, recording | 33% | 7.5% |
| Extension, idle | 32% | 0% |
| Mark One, idle | 14% | about 5% |

Mark One while recording measured 29% one morning and 37-41% that
afternoon, both before and after the change. Its own busy time is
decoding (libavcodec 73%, the NV12 interleave in vImage 9%), and a plain
wall against a busy scene made no difference (37-40% either way), so
the spread is unexplained; Apple's decoder should remove most of it.
QuickTime went from 8% to 23% across the same runs, also unexplained
(its preview window may have been hidden the first time).

The first launch after installing extension build 4 failed with
"Couldn't open the Mark One camera's input": Mark One found the device
before the new extension was ready, and then waits for the camera to
be reconnected. Reopening Mark One fixed it.

## Camera extension updates (2026-11-09)

Updating the camera extension can lose the Mark One camera until the
Mac restarts. Seen going 0.1/2 to 1.0/1 and again 1.0/1 to 1.0/2, so
it isn't the build number. The system log shows why: sysextd asks
registerassistantservice to stop the old extension (launchd remove,
EINPROGRESS), then 4 ms later to start the new one, which it skips
with "extension is already running" because the old process hasn't
exited yet. The new version is then activated and enabled but never
launched, and reopening Mark One only gets "alreadyActive". SIP blocks
`launchctl kickstart` on registerassistantservice, but killing it
works: `sudo kill -KILL $(pgrep -x com.apple.cmio.registerassistantservice)`.
launchd restarts it, it launches the new extension, and Mark One then
needs reopening. A Mac restart also fixes it. Others hit the same race
(kortexa-ai/aicamera#73, grahamgilbert/movembercam#6 and #9; Apple
forums thread 756234). Mark One no longer replaces the extension with
the same version. To keep users clear of it otherwise (in `TODO.md`):

- Give the extension its own version, and change it only when the
  extension changes, so app-only updates don't replace it. Today it
  inherits `CURRENT_PROJECT_VERSION`.
- After activating, check that the Mark One device appears. If it
  doesn't, say a restart is needed to finish the update. movembercam
  also recovers with deactivate, wait, activate, which costs the user
  a second approval.

## FFmpeg and entitlements (2026-11-09)

Written while preparing for the App Store. Mark One is free and ships
directly instead (2026-11-11), but the FFmpeg and entitlement details
still apply.

- FFmpeg: Settings > About credits FFmpeg 9.0.2 (libavcodec, libavutil),
  links the exact source release, and shows the LGPL 2.1 text from the
  copy in the app (`Vendor/ffmpeg/COPYING.LGPLv2.1`, a resource in
  `project.yml`). The libraries are built from unmodified source with
  `scripts/build-libavcodec.sh` and ship as separate dynamic libraries,
  which LGPL relinking needs.
- Entitlements are camera, USB and the system extension install, with
  the hardened runtime for notarization. Mark One dropped the sandbox
  (and with it the network client and user-selected files entitlements)
  when it moved to direct distribution (2026-11-09). Debug captures
  (`SaveCapture`) go to ~/Library/Caches.
- Camera extensions are an App Store delivery method (WWDC 2022 session
  10022). `com.apple.developer.system-extension.install` needs a
  provisioning profile that grants it.
- Review risks that no code change settles: guideline 2.5.2 bars
  downloading code that changes the app, and says nothing about
  firmware for an accessory. Mark One also modifies Olympus's firmware,
  whose license (shown by the update server) forbids modifying it.
  Mark One ships only its own edits and downloads the firmware from
  Olympus, but review may still object. Outside the App Store (Developer
  ID and notarization) neither applies.

## FaceTime (2026-11-12, macOS 27)

FaceTime listed Mark One and ticked it, but kept showing the Mac's own
camera, with Automatic Camera Selection on or off. Photo Booth showed
Mark One fine. FaceTime hands capture to its video service,
`avconferenced`, and that logged `VCVideoCaptureServer
setCameraPerClientRequest: ignoring because captureDevice is nil` each
time FaceTime picked Mark One: it couldn't find the device.

`avconferenced` had been running since Nov 8, and the camera extension
was replaced three times after that (versions 1 to 4, the last on Nov
10). Restarting it (`killall avconferenced`, which launchd restarts,
and which drops any call in progress) fixed it at once: it logged
`Camera is set to 5B2F6E1C-…, deviceType=AVCaptureDeviceTypeExternal`
and FaceTime showed the E-M5. So the service keeps a stale device list
across extension replacements; apps that build their own list, like
Photo Booth, aren't affected. A restart of the Mac also clears it.


## Processes don't see the camera come back (2026-11-13, macOS 27)

A process that's running when the camera extension is switched on in
System Settings doesn't see the Mark One camera, and keeps not seeing
it. Tested with three probes while Media Extension was switched off and
on (scratch code, not kept): one polling CoreMediaIO's device list every
second, one also listening for changes to that list
(`CMIOObjectAddPropertyListenerBlock` on `kCMIOHardwarePropertyDevices`),
and one watching AVFoundation (a `DiscoverySession`, its `devices`, and
the connected and disconnected notifications). All three saw the camera
go within a second. None saw it come back, a minute later, while
sysextd had it `activated_enabled`, the extension was running and a
fresh process listed it at once. A fourth probe, started while the
camera was off, didn't see it arrive either.

So, after the extension is switched on (or replaced, as in "FaceTime"
above):

- Mark One itself can't find its camera, and can't send it frames,
  until it's reopened. This is the first run for everyone: Mark One
  opens, then the camera is allowed during setup.
- Video apps that were open don't list Mark One until they're reopened,
  and FaceTime until `avconferenced` restarts (it outlives FaceTime).
- Whether the camera is switched on has to come from sysextd (a
  properties request), not from the device list.
