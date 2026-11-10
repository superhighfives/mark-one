# To do

The goal is software that feels like magic: plug in the camera, open a
video call, and it works, with nothing to press on the camera or in
Mark One.

## Next

- [ ] **Long session.** Stream for more than 30 minutes with a card in.
  Check that Mark One's scheduled restart (at 3.5 GB of video or 100
  minutes) is only a short freeze, that video carries on past 30
  minutes, and the size and bitrate the restart logs. The same session
  answers:
  - whether the movie writer stops at 4 GB (if not, restart only near
    the 2-hour limit)
  - whether the card's free space shrinks
  - what the "Slow pass" log says about the video pauses
- [ ] **Video pauses.** A couple of times a minute the video stops for
  0.2-1.4 s, then the missed frames arrive at once: the camera keeps
  encoding while Mark One isn't reading. Fix the cause the long session
  points to.

## Before launch

### Mark One

- [ ] **Extension updates.** Replacing the camera extension can leave no
  camera until the Mac restarts (see "Camera extension updates" in
  `NOTES.md`). Give the extension its own version so app-only updates
  don't replace it, and if the Mark One device doesn't appear after an
  update, say a restart is needed.
- [ ] **Battery level.** The camera reports few steps: it read 100% for
  45 minutes, then 50% while its own icon flashed empty, then it died.
  Record which values it sends, then show the camera's levels (full,
  low, empty) instead of a percentage, and warn when it's low.

### Webcam firmware

Move what Mark One patches into camera memory each session into the
firmware itself, active only in webcam mode, so normal movies still go
to the card.

- [ ] **Webcam mode switch.** A flag Mark One sets when it connects,
  which the patched code checks.
- [ ] **No SD card.** Record without a card in. Today the camera won't
  start recording without one, though nothing is written to it.
- [ ] **No empty movie files.** Each session leaves a 0-byte movie on the
  card (91 so far), and the camera's file numbering stops at 9999.
- [ ] **Card writes and time limits** in webcam mode only, replacing the
  runtime patches.

### Release

- [ ] Pages for the support, marketing and privacy URLs.
- [ ] A Release build.

### Website

- [ ] Check its claims once the tests pass: no recording time limit, and
  the card untouched after long sessions.
- [ ] Update the firmware box: Mark One restores Olympus's firmware over
  USB ("Going back"), and setup takes a few minutes plus the camera's
  own install.

## After launch

- [ ] **Power.** The E-M5 doesn't run from USB power. Try the dummy
  battery and power adapter (on order) for long calls.
- [ ] **Fewer restarts.** If 4 GB isn't a limit, restart only near the
  2-hour cap. Values above about 6.6 hours would likely overflow the
  muxer's 90 kHz clock.
- [ ] **Apple's video decoder.** Hardware decoding would use less CPU and
  battery than libavcodec, but Apple's hardware decoder rejects every
  frame of this stream and the software one about 1 in 100. Measure
  Mark One's CPU use first; explore only if it's significant.
  `NOTES.md` lists what has been ruled out.
- [ ] **HDMI live view (optional).** The `hdmi-liveview` patch is built
  but has never been tried on a camera. It would help anyone using a
  capture card.

## Done recently

- The 30-minute stop, the Mach port leak, QuickTime failing on repeated
  timestamps, gray frames, and asking for a missing card (2026-11-09).
- Unplugging mid-call leaves the camera usable, and plugging back in
  works (2026-11-09).
- USB firmware installs work on a camera Mark One has set up
  (2026-11-09).
