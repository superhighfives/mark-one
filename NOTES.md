# E-M5 (Mark I) as a Mac webcam

Research notes for getting live video from an original Olympus OM-D E-M5
into macOS as a webcam by patching the camera firmware. Everything here
targets firmware 2.3, so update the camera to 2.3 before flashing anything.

## To test when the camera is on

- Time limit: run `ptp.py shoot`, record and stream past 30 minutes.
  Watch for the recording stopping, or a hiccup around 27 minutes (4 GB
  at 20 Mbps), when the QuickTime writer may split or stop the file.
- Card space: after a long streamed recording, check that the card's
  free space didn't shrink.

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
- In-app pipeline (works; no Python, as the App Store needs): Mark
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
limitation with something in this encoder's slice data.

OpenH264 2.7 (BSD license) decodes every frame without error but not
exactly: it matches libavcodec on Baseline streams, and differs on High
profile ones (x264 test streams and the camera's), so it doesn't fully
support High profile. libavcodec is the decoder that gets this stream
right, so Mark One uses it. `scripts/build-libavcodec.sh` builds FFmpeg
with only the H.264 decoder (LGPL 2.1, no GPL parts) as universal
dynamic libraries in `mac/MarkOne/Vendor/ffmpeg`, which the app embeds.
With low-delay mode and one thread, every frame of the one-minute capture
comes out as soon as it goes in, in 4.5 ms including the NV12 copy, and
matches PyAV's output exactly. Before App Store release: credit FFmpeg
and link to the source in the app, and include the LGPL text.

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
  picture mode 0x136, USB mode 0x76 (0xff is Auto), sleep 0x2f, auto
  power off 0xb2, backlit LCD 0xfe.
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

## Webcam USB choice (built, not flashed)

The `webcam` patch set in `scripts/build.py` adds a "Webcam" choice to the
camera's USB prompt (Storage, MTP, Webcam, Print, Exit) and to Custom
menu > USB Mode and bakes in Mark One's run-time helpers. `version=X.Y`
sets the version the camera reports. Build it on top of usb-tools:

```sh
uv run scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN \
  patched/usb-tools+webcam/E0972300.BIN usb-tools webcam version=1.0
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
  displayed version (setting 0xc082) at boot; the PTP DeviceInfo version
  has a hardcoded 0x2300 at 0x7f0dd970. A version below 2.3 keeps
  Olympus's updater willing to install stock 2.3 over it. Whether the card
  updater accepts a lower version than the one installed is untested;
  `patched/version-test` (usb-tools with version 1.0 and nothing else)
  tests it.

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

## Installing firmware over USB (research, 2026-11-08)

Goal: Mark One installs the webcam firmware itself, with no SD card.
Nothing here is tested on the wire yet.

### In the camera

The camera has a firmware update protocol over PTP, separate from the
card update (`tpc_ptp_fwup_op.c`, log prefix `[TPCFirmup]`). The handlers
are registered around 0x7f0d49a4, in the command list my earlier notes
put at connection modes 0 and 5 (0x7f0e0773), not in MTP (mode 4):

| Opcode | Handler | Name in the log | Data |
| --- | --- | --- | --- |
| 0x911c | 0x7f0dd2be | GetFirmwareUpdateMode | none |
| 0x9122 | 0x7f0dd2e2 | second entry into GetFirmwareUpdateMode | none |
| 0x9120 | 0x7f0dd36f | GetVersions | to the computer |
| 0x9124 | 0x7f0dd3e4 | GetLanguageCode | to the computer |
| 0x9125 | 0x7f0dd773 | SendFirmDataInfo | from the computer |
| 0x9119 | 0x7f0dd4d8 | SendObjectSplit | from the computer |
| 0x9121 | 0x7f0dd586 | FirmwareCheck | none |
| 0x9123, 0x9117 | 0x7f0dd6cb | UpdateInitiate | none |

SendFirmDataInfo compares the response against 0x2001 and the values
0xb001, 0xb011, 0xb021 and checks a 0x1ca66100 constant; not traced
further.

### Olympus's side

- OM Workspace (macOS and Windows, 2.5) replaced Olympus Digital Camera
  Updater. Its procedure: take the card out, connect USB, choose
  Storage on the camera, then Camera > Update, and wait for "OK" on the
  camera. https://support.jp.omsystem.com/en/support/imsg/digicamera/qa/contents/ow/ow_a2.html
- Firmware comes from a POST of `<firmware_demand>` XML to
  `https://fw01.om-digitalsolutions.net/ww_inform/fcache.do` (User-Agent
  `Olympus`, `<hard_code>OLY{E097}...` for this model, presumably), which
  answers with a signed download URL for the latest version only.
  Documented for the E-M10 in github.com/matozoid/em10_1
  (`docs/firmware/update-server.md`); not tried for E-097.
- The same project decompiled OM Workspace's OlyCameraLib.dll
  (`docs/usb-protocol/firmware-update.md`, unverified on the wire): 0x9125
  starts a transfer with a 0x3c-byte ObjectInfo-like dataset (StorageID
  0x80000001), 0x9119 sends 0xf800-byte chunks with (offset, length),
  then 0x9123 starts the update and the host polls 0x9122 while the
  camera reboots into its updater. OlyGin.dll has ChangePid and
  RebootCamera, so the camera may switch USB product ID to update.
  libgphoto2's ptp.h has only commented guesses for 0x911c-0x9126.
- Olympus says firmware can't be reverted, and the server only offers
  the latest version. Whether the camera itself refuses a lower version
  is unknown; see the version test under "Webcam USB choice".

### Next

Record a real update: with the camera on a version below 2.3 (the 1.0
version test), OM Workspace should offer stock 2.3. Capture that session
(USB capture on the Mac or in a Windows VM, or log incoming PTP commands
on the camera with a hook like `asm/trace.s`) to confirm the opcodes,
parameters, chunk size and how the camera enters update mode. That run
also proves the way back to stock.

## Recording time limit (patch ready, untested)

0x7e7bbe71 works out how long a movie may run and logs "MAX Time" (what
the card's free space allows, d3) and "Limte Time" (d2, the limit),
stored in frames at +32 and +40 of the recorder's state. The format
maximum is 1740 s for MOV Full HD and HD (`mov 1740,a3` at 0x7e7bbf89),
7200 s for SD, and the limit is the smaller of that and the card figure.
`ptp.py shoot` now raises the maximum to 32767 s and uses it for both
values (RUNTIME_PATCHES 'time limit'). Untested; also unknown is what the
QuickTime writer does at 4 GB ("[QT] AVSCA_INF_DIV_FILESIZE" and
"REC_FILESIZE" are only logged at 0x7e7a85ee/0x7e7a85fc), which the
muxer would reach after about 27 minutes at 20 Mbps even with card
writes skipped.

Next: test the time limit (record past 30 minutes).

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
