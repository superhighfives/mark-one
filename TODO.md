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
- [ ] **Battery steps.** Mark One shows full, low or empty and logs each
  new reading ("Camera battery reads"). So far: 100, then 50 once the
  camera's icon flashes empty. Check the thresholds against a full
  discharge.

### Webcam firmware

Revision 2 records in webcam mode with no card, creates no movie file and
lifts the time limits (see "Recording without a card" in `NOTES.md`).

- [ ] **Restart after a USB install.** The camera goes back to its old
  picture, still running the old firmware, until it's switched off and
  on. Find the firmware's restart routine and have Mark One call it when
  the install finishes, then say "it'll restart, then choose Webcam".
- [ ] **Long session with no card.** Stream for more than 30 minutes
  with no card, and past Mark One's first scheduled restart.
- [ ] **Drop the runtime patches on revision 2.** Mark One still applies
  'card writes', 'time limit' and 'muxer time limit' each session; on
  revision 2 they're redundant.
- [ ] **Remove the empty movie files** that earlier sessions left on
  cards (96 on the test card), or tell users they can delete them.

### Direct distribution

- [ ] **Developer ID build** with the system extension entitlement,
  notarized.
- [ ] **Updates** with Sparkle.

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

- No sandbox: Mark One writes the firmware to the card itself, with no
  file panel (2026-11-09).
- Recording with no card, no empty movie files and no time limits in
  webcam mode: firmware revision 2 (2026-11-09).
- Battery shown as full, low or empty (2026-11-09).
- The 30-minute stop, the Mach port leak, QuickTime failing on repeated
  timestamps, gray frames, and asking for a missing card (2026-11-09).
- Unplugging mid-call leaves the camera usable, and plugging back in
  works (2026-11-09).
- USB firmware installs work on a camera Mark One has set up
  (2026-11-09).
