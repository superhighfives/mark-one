# To do

Everything left to do for Mark One, in one place. `NOTES.md` has the
research behind each item.

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

- [ ] **FaceTime after an extension update** (2026-11-12, macOS 27):
  FaceTime ignored the Mark One camera until its video service
  (`avconferenced`) restarted, then worked (see "FaceTime" in
  `NOTES.md`). Still to find out: whether a first install has the same
  problem, on a Mac where `avconferenced` is already running. If it
  does, setup should say to restart the Mac, or the help page should.

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
- [x] **Long session with a card in, past 4 GB with no restart**
  (2026-11-11, revision 4): 1 GB every 8 minutes, past 4 GB at 31.9
  minutes, and on until the battery ran out at 37 minutes (about 4.6
  GB). No hang, so the 3.5 GB restart is gone; the 100-minute one stays.
  The first try (2026-11-10) ended at the 3.5 GB restart, when QuickTime
  stopped at the gray placeholder (fixed in a9b0a2f).
  The card holds 2.3 GB in all, so the session wrote nothing to it.
- [x] **Empty movie files** from earlier sessions: only on the test card
  (only pre-release firmware made them), so delete them there; Mark One
  doesn't.

### Decide

- [x] **License** (2026-11-12): MIT, in `LICENSE`, with the README
  listing what's under other terms (FFmpeg's LGPL, Sparkle, om-emu's
  `olyfw.py`, which is downloaded rather than copied because it has no
  license).

### Direct distribution

Downloads live on superhighfives.com (`~/Development/superhighfives.com`,
Next.js on Cloudflare Workers through OpenNext), next to Pika.

```
/mark-one                       product page, Download (or Coming soon)
/mark-one/download              streams the latest DMG from R2
/releases/mark-one/feed         Sparkle appcast
/releases/mark-one/<v>.dmg      update files
```

**In the app**

- [x] **Developer ID build** with the system extension entitlement,
  notarized. The archive and export work (2026-11-10): every nested
  binary is signed with Developer ID, the hardened runtime and a
  timestamp. The notarytool profile `mark-one` is saved
  (hi@superhighfives.com, 2026-11-12).
- [x] **Sparkle** 2.10 through Swift Package Manager (2026-11-10).
  `App/Updater.swift`, with "Check for Updates…" under Settings > About
  and the automatic check under Settings > General. Scheduled checks
  wait while the camera is streaming, so an update prompt never lands
  mid-call. `SUFeedURL` and `SUPublicEDKey` are in `App/Info.plist`. The
  key is Mark One's own, in the login keychain under the account
  `mark-one`.
- [x] **Sparkle key backed up** (2026-11-12). To restore it on another
  Mac: `generate_keys --account mark-one -f <file>` (in
  `build/SourcePackages/artifacts/sparkle/Sparkle/bin`).
- [ ] **Updates and the camera extension.** Sparkle only replaces the
  app. The extension changes only when Mark One asks the system to
  activate it, so updates that keep the extension's build number are
  safe. Release notes for updates that change the extension should say a
  restart may be needed (see "Extension updates" above).
- [x] **Release script** (`scripts/release.sh`, 2026-11-10): archives,
  exports with Developer ID, notarizes and staples the app, makes and
  signs the DMG, notarizes and staples that, signs it for Sparkle,
  uploads it to R2 with `--upload`, and prints the front matter for the
  changelog entry. First full run (2026-11-12, 1.0 build 2, not
  uploaded): app and DMG notarized and stapled, Gatekeeper accepts both,
  and the Sparkle signature checks out against the app's public key.
  Installed from the DMG, it streams live at 30 fps.
- [x] **Builds from source** (2026-11-11): the README's "Build it
  yourself". Those builds have no update feed.

**On superhighfives.com**

- [x] **Release files:** the private R2 bucket `mark-one-releases`
  exists (empty). `/releases/mark-one/Mark-One-<v>.dmg` serves the files
  publicly for Sparkle, and `/mark-one/download` serves the latest.
- [x] **Appcast:** `changelog/mark-one/<version>.md`, in the same format
  as Pika's, and `/releases/mark-one/feed`. `generateAppcast.ts` now
  takes settings per app, and Pika's feeds are unchanged.
- [x] **Privacy page** covers Cloudflare, GitHub Sponsors, update checks
  and the Olympus firmware download. No live page loads an analytics
  script.
- [x] **Coming soon** (2026-11-11): `available` in `src/data/markone.ts`
  is off, so the page shows "Coming soon" with no download or source
  link, and `/mark-one/download` returns 404.
- [ ] **Test end to end:** download from the page, then publish an
  update and watch Sparkle install it. Check that downloads report their
  size, so browsers show progress.

### Release

- [x] Screenshots (2026-11-12): `swift scripts/capture-screenshots.swift`
  walks through the shots in `screenshots/shots.json`, opens each
  window and grabs it into `screenshots/raw/`. The website lays them out
  in HTML with its own captions.
- [ ] A support page, or point support at the repo's issues.
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
- [ ] **Shorter restarts.** Mark One restarts the recording every 100
  minutes, before the 2-hour cap, and the picture freezes for about 5 s,
  almost all of it waiting for the camera to report it's recording
  again (see "Exact frame boundaries" in `NOTES.md`). Find out why that
  check takes nearly 5 s. Values above about 6.6 hours would likely
  overflow the muxer's 90 kHz clock.
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
- FFmpeg credit and license in the app, no Downloads entitlement
  (2026-11-09).
