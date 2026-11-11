# To do

The goal is software that feels like magic: plug in the camera, open a
video call, and it works, with nothing to press on the camera or in
Mark One.

## Next

- [x] **Video pauses.** Fixed by revision 3, which lists each frame's
  address and size (`asm/frames.s`). A 71-minute recording (2026-11-10)
  froze only at the two scheduled restarts and once for 0.43 s
  downstream of Mark One, against 27 freezes in 56 seconds on revision
  2. See "Exact frame boundaries" in `NOTES.md`.
- [ ] **Hard freeze at 21.6 minutes** (2026-11-09, revision 2, card in):
  the camera froze mid-stream and needed a battery pull. A 26-minute run
  afterwards didn't freeze, nor did a 71-minute run on revision 3
  (2026-11-10). Watch for it in long sessions.

## Before launch

### Mark One

- [ ] **Extension updates.** Replacing the camera extension can leave no
  camera until the Mac restarts (see "Camera extension updates" in
  `NOTES.md`). The extension has its own build number in `project.yml`
  (4), changed only when the extension changes. After installing, Mark
  One checks that the Mark One camera appears within 10 s and otherwise
  asks for a restart, and it retries opening the camera's input every
  2 s instead of waiting for the camera to be reconnected. Not yet seen
  working: the restart message only shows when the race happens.
- [x] **Battery steps.** A full discharge (2026-11-10) read 100, 50 once
  the camera's icon flashes empty, then 5 nine seconds before it switched
  itself off: Full, Low and Empty. USB installs now wait for Full.

### Webcam firmware

Revision 2 records in webcam mode with no card, creates no movie file and
lifts the time limits (see "Recording without a card" in `NOTES.md`).

- [x] **Restart after a USB install** (2026-11-10): the camera restarts
  itself after OK (see "Restarting after a USB install" in `NOTES.md`).
  Tested with a script; still to try from Mark One's Reinstall.
- [x] **Connect as a webcam without asking** (2026-11-10): USB Mode
  Webcam, on by default, in setup and Settings. Docs: to import photos
  over USB, set Custom Menu > USB Mode back to Auto, or turn it off.
- [x] **Long session with no card** (2026-11-10): 71 minutes, past two
  scheduled restarts.
- [ ] **Long session with a card in, past 4 GB with no restart.** Mark
  One skips the runtime patches on revision 2 and later ('card writes',
  'time limit', 'muxer time limit'; revision 2's hooks do the same).
  The first try (2026-11-10) ended at the 3.5 GB restart: the camera
  takes about 5 s to record again, the extension's gray placeholder
  replaced the last picture after 3 s, and QuickTime stopped recording
  at the switch. Fixed in a9b0a2f (Mark One holds the last picture).
  Now test whether the restart is needed at all:
  - The installed build has `NoSizeRestart` on (`defaults write
    com.superhighfives.markone NoSizeRestart -bool true`). Reopen
    QuickTime first.
  - Record about 35 minutes. Mark One logs "Recorded N GB in M minutes
    without restarting" each GB.
  - If video keeps going past 4 GB: remove the 3.5 GB restart, leaving
    the 100-minute one.
  - If it freezes for good: don't switch the camera off yet; read the
    stuck-camera peeks in `NOTES.md` ("Peeks for a stuck camera"), then
    power cycle.
  - Either way: the card gets no new files and keeps its free space.
    Then `defaults delete com.superhighfives.markone NoSizeRestart`.
- [x] **Empty movie files** from earlier sessions: only on the test card
  (only pre-release firmware made them), so delete them there; Mark One
  doesn't.

### Direct distribution

```
```

**In the app**

- [x] **Sparkle** 2.10 through Swift Package Manager (2026-11-10).
  `App/Updater.swift`, with "Check for Updates…" under Settings > About
  and the automatic check under Settings > General. Scheduled checks
  wait while the camera is streaming, so an update prompt never lands
  mid-call. `SUFeedURL` and `SUPublicEDKey` are in `App/Info.plist`. The
  key is Mark One's own, in the login keychain under the account
  `mark-one`.
- [ ] **Back up the Sparkle key**: `generate_keys --account mark-one -x
  <file>` (in `build/SourcePackages/artifacts/sparkle/Sparkle/bin`), and
  keep the file in a password manager. Losing it means no more updates
  for existing copies.
- [ ] **Updates and the camera extension.** Sparkle only replaces the
  app. The extension changes only when Mark One asks the system to
  activate it, so updates that keep the extension's build number are
  safe. Release notes for updates that change the extension should say a
  restart may be needed (see "Extension updates" above).
- [x] **Release script** (`scripts/release.sh`, 2026-11-10): archives,
  exports with Developer ID, notarizes and staples the app, makes and
  signs the DMG, notarizes and staples that, signs it for Sparkle,
  uploads it to R2 with `--upload`, and prints the front matter for the
  changelog entry. Tested up to notarization.

**On superhighfives.com**

- [x] **Appcast:** `changelog/mark-one/<version>.md`, in the same format
  as Pika's, and `/releases/mark-one/feed`. `generateAppcast.ts` now
  takes settings per app, and Pika's feeds are unchanged.

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
- [ ] **Shorter, rarer restarts.** Mark One's scheduled restart at 3.5 GB
  (about every 28-33 minutes at 15-18 Mbps) freezes the picture for
  about 5 s, almost all of it waiting for the camera to report it's
  recording again (see "Exact frame boundaries" in `NOTES.md`). Find
  out why that check takes nearly 5 s. If 4 GB isn't a limit (being
  tested, see "Long session with a card in"), restart only near the
  2-hour cap. Values above about 6.6 hours would likely
  overflow the muxer's 90 kHz clock. Also check whether the card's free
  space shrinks in a long session.
- [x] **Apple's video decoder.** Mark One decodes with VideoToolbox on
  revision 3 and libavcodec otherwise, or when the hardware fails:
  about 12% of a core while streaming, down from 37-41% (see "Apple's
  decoder on exact frames" in `NOTES.md`).
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
