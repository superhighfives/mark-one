# To do

Everything left to do for Mark One, in one place. `NOTES.md` has the
research behind each item, and the git history has what's done.

The goal is software that feels like magic: plug in the camera, open a
video call, and it works, with nothing to press on the camera or in
Mark One.

## Next

- [ ] **Not recording after a night idle** (2026-11-17, 1.0.0, work
  laptop): ready from 20:20, the camera ignored REC at 08:01 though it
  still answered over USB, until it was switched off and on. Not
  reproduced on this Mac:
  - Not the camera's own sleep (0x2f, 6) or auto power off (0xb2, 240
    minutes): with auto power off at 1 minute, it still recorded after 3
    minutes idle, both with Mark One checking the battery and with Mark
    One paused (SIGSTOP), sending nothing.
  - Not a Mac sleep of 10 minutes, or of 3 hours (2026-11-17). In the
    3 hours this Mac only reached dark wake: Mark One kept running and
    the camera answered every 30 s, so the camera was never left alone.

  Next: run 1.0.2 on the work laptop with Detailed logging on (Settings
  › General › Troubleshooting). It logs the Mac's sleep and wake, and a
  line a minute while Mark One waits. If REC is ignored again, don't
  switch the camera off and on before reading its state.
- [ ] **Extension updates.** Replacing the camera extension can leave no
  camera until the Mac restarts (see "Camera extension updates" in
  `NOTES.md`). The extension has its own build number in `project.yml`
  (4), changed only when the extension changes, and updates that don't
  change it leave it alone (1.0.0 to 1.0.1 kept the running extension,
  2026-11-16). After installing, Mark One checks that the Mark One camera
  appears within 10 s and otherwise asks for a restart, and it retries
  opening the camera's input every 2 s instead of waiting for the camera
  to be reconnected. Not yet seen working: the restart message only
  shows when the race happens. It matters from the first update that
  changes the extension.

## Distribution

Downloads live on superhighfives.com (`~/Development/superhighfives.com`,
Next.js on Cloudflare Workers through OpenNext), next to Pika. `/release`
does the rest.

```
/mark-one                       product page, Download
/mark-one/download              redirects to the latest DMG on GitHub
/releases/mark-one/feed         Sparkle appcast, from changelog/mark-one/
github.com/superhighfives/mark-one/releases   DMGs and deltas
```

- [ ] **Homebrew cask.** `mark-one` is ready on the `mark-one` branch of
  the local homebrew-cask tap (modelled on Pika's; livecheck reads the
  Sparkle feed). `brew audit --new` passes except for notability: the
  repo needs 75 stars, or 30 forks or watchers. Once it has them, fork
  Homebrew/homebrew-cask, open the PR, and when it's merged change
  `brewInstall` in `superhighfives.com/src/data/markone.ts` to
  `brew install --cask mark-one` and remove the cask from the
  superhighfives/tools tap. Until then the site shows
  `brew install --cask superhighfives/tools/mark-one` (2026-11-14).

## Later

- [ ] **A message after unplugging.** Unplugging mid-call leaves the
  screen dark for up to 10 seconds before the camera goes back to
  normal, which can look frozen. Show the camera's own "One Moment"
  warning (0x11) from `asm/unplug.s` until the camera's back. Found how
  to show it (2026-11-16, "A message after unplugging" in `NOTES.md`);
  next, try `asm/wait.s` on the camera, then add it to the stub as a
  firmware revision and test unplugging mid-call and in Storage and MTP.
- [ ] **Shorter restarts.** Mark One restarts the recording every 100
  minutes, before the 2-hour cap, and the picture freezes for about 5 s,
  almost all of it waiting for the camera to report it's recording
  again (see "Exact frame boundaries" in `NOTES.md`). Find out why that
  check takes nearly 5 s. Values above about 6.6 hours would likely
  overflow the muxer's 90 kHz clock.
- [ ] **A flicker when video comes back on.** After a short break
  (under 3 s), turning video back on in a call shows the picture from
  when it was turned off for a moment. The extension repeats the last
  frame it had through gaps, and that one is old by then. Mark One no
  longer leaves old frames in the queue (1.0.1), but the rest has to be
  fixed in the extension: forget the last frame when the last app stops,
  and skip frames more than about 0.2 s old. Changing the extension can
  need a restart to finish updating, so do it with the next extension
  change.
- [ ] **More camera controls.** Exposure (Auto, Aperture and Shutter
  priority, Manual, with aperture, shutter speed and ISO) and
  stabilization are in Settings › Picture (1.0.3). Left:
  - Art filters: they're picture mode 0xac 8-18, and switch at once, but
    the camera then stops recording, and Diorama hung it until the
    battery came out ("Movie exposure and art filters" in `NOTES.md`).
    Try them with a recording restart, without Diorama, and check the
    frame rate.
  - The aperture list doesn't know the lens: check what the camera does
    with an f-number the lens can't reach (f/1.4 on a kit zoom).
  - Contrast, sharpness, saturation and gradation; metering mode; AE
    lock. Find each ID as for the others (`scripts/ptp.py settings`).
- [ ] **Center Stage (future idea).** Keep the person in frame as they
  move, like Center Stage on Apple's cameras. macOS only offers Center
  Stage for Apple's own cameras, so Mark One would do it itself: find
  faces with Vision and crop and zoom smoothly within the 1080p frame,
  with a checkbox in Settings to turn it on. Needs a look at how much
  sharpness the crop costs and whether it fits in the 0.2 s delay.
- [ ] **A sound when focusing (nice to have).** An optional click when
  Focus or its shortcut focuses the camera, with a checkbox in Settings
  to turn it on. Best would be the E-M5's own focus beep, recorded from
  the camera.
