# Release

Cut a new release of Mark One: version bump, notarized build, DMG and deltas
(releasecast), GitHub release, website changelog (which is the Sparkle feed),
and deploy. Modelled on Pika's `/release` in `~/Development/pika-workspace`.

Supports flags via `$ARGUMENTS`:
- `--dry` — dry run: build and check everything, but skip notarizing the DMG,
  make the GitHub release a draft, don't push the website, and undo the
  version bump at the end.

## Instructions

Follow these phases in order. Ask for confirmation before anything
irreversible (pushing, the GitHub release, the website). If a phase fails,
stop and report it; don't carry on to the next one.

Run `/pre-release` first if it hasn't been run since the last change.

### Where things are

| What | Where |
|---|---|
| App source | this repo, `mac/MarkOne/` (XcodeGen: `project.yml`) |
| Version and build | `mac/MarkOne/project.yml`: `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` (under `settings.base`) |
| Camera extension's build | `project.yml`, `MarkOneCamera`'s own `CURRENT_PROJECT_VERSION` |
| Firmware edits | `mac/MarkOne/App/Resources/webcam-firmware.json`, from `scripts/build.py` |
| Build script | `scripts/build-release.sh` (archive, Developer ID export, extension check, notarize the app) |
| Release output | `mac/MarkOne/build/release/VERSION/` (gitignored), then filed in the releases repo |
| Releases repo | `~/Development/pika-workspace/releases` ([superhighfives/releases](https://github.com/superhighfives/releases)), `Mark One/VERSION/`: DMG, delta, appcast, `VERSION.md` and `MarkOne-VERSION.xcarchive.zip` |
| Sparkle tools | `mac/MarkOne/build/SourcePackages/artifacts/sparkle/Sparkle/bin` (after a build) |
| releasecast | `npx releasecast@0.0.13` (needs `--account` and `--profile`; this Mac's npm skips packages less than a day old) |
| Website | `~/Development/superhighfives.com`, `changelog/mark-one/VERSION.md` |
| Feed | https://superhighfives.com/releases/mark-one/feed (skips `beta: true`) |
| GitHub | `superhighfives/mark-one`, tag `VERSION`, assets `Mark-One-VERSION.dmg` and `Mark-OneBUILD-FROM.delta` |
| Homebrew | `superhighfives/homebrew-tools` (local clone: `$(brew --repo superhighfives/tools)`), `Casks/mark-one.rb`; and the unsubmitted `mark-one` branch of `$(brew --repo homebrew/cask)` |

Configuration: Apple ID `hi@superhighfives.com`, notary keychain profile
`mark-one`, Sparkle key in the keychain under account `mark-one` (the app's
`SUPublicEDKey` matches it; never sign with Pika's default key).

---

### Phase 0: Preflight

Check quickly; if any fail, stop and say what's missing.

1. On `main`, clean working tree (`git status --porcelain` empty), up to date with `origin/main`.
2. `xcodebuild -version`, `xcodegen --version`, `gh auth status`, `which create-dmg` (sindresorhus's npm package, not Homebrew's).
3. `mac/MarkOne/Local.xcconfig` has `DEVELOPMENT_TEAM`, and a Developer ID Application certificate for that team is in the keychain (`security find-identity -v -p codesigning`).
4. `xcrun notarytool history --keychain-profile mark-one` works.
5. The Sparkle key: `security find-generic-password -a mark-one -s https://sparkle-project.org` finds it.
6. **Live releases only:** the GitHub repo is public (`gh repo view superhighfives/mark-one --json visibility`). Release downloads from a private repo fail for everyone else, so stop if it's private.
7. The website repo is on `main`, clean apart from `bun.lock`, and up to date.
8. The releases repo (`~/Development/pika-workspace/releases`) is on `main`, clean and up to date.
9. Screenshots: `which cwebp webpinfo` (`brew install webp`), and the terminal has Screen Recording permission (`swift` with `import CoreGraphics; print(CGPreflightScreenCaptureAccess())` prints `true`). Without it, ask the user to turn it on in System Settings › Privacy & Security and reopen the terminal.

Report the mode (live or dry run).

---

### Phase 1: Version

1. Read the current `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml`, and the latest release: the newest `changelog/mark-one/*.md` on the website and the newest tag (`git tag --sort=-v:refname | head -1`).
2. Ask for:
   - **New version**, always three parts (`X.Y.Z`, like `1.0.1`; show the current one). The site sorts versions as semver, so `1.1` alone won't do.
   - **Release title** (a short name).
3. **Build** = current `CURRENT_PROJECT_VERSION` + 1. It must be higher than every released build: Sparkle compares build numbers.
   - The very first release keeps the current build if nothing has been released yet (1.0 is build 2).
4. **Camera extension:** if anything in `mac/MarkOne/Extension/` changed since the last release tag, ask whether to bump `MarkOneCamera`'s build too. Otherwise leave it alone: updating the extension can lose the camera until a restart (NOTES.md, "Camera extension updates").
5. Confirm:
   ```
   Version:    X.Y.Z
   Build:      N
   Extension:  M (unchanged / bumped)
   Title:      "Title"
   Mode:       live / dry run
   ```
6. Edit `project.yml`, check it with `git diff`, then commit: `Mark One: Version X.Y.Z (build N)`. Push in live mode only, after confirming.

---

### Phase 2: Checks specific to Mark One

1. **Firmware edits are current.** `WEBCAM_REVISION` in `scripts/build.py` matches `"revision"` in `webcam-firmware.json`, and rebuilding the edits gives the same file:
   ```sh
   uv run --frozen scripts/build.py fw/OLY_E_097_2300_0000_0000.BIN /tmp/markone-check/E0972300.BIN usb-tools webcam --edits /tmp/markone-check/edits.json
   cmp /tmp/markone-check/edits.json mac/MarkOne/App/Resources/webcam-firmware.json
   ```
   (Needs `fw/` from `scripts/setup.sh`.) If they differ, stop: the app would install firmware that doesn't match the source.
2. **No test settings left in code:** `UserDefaults` keys used only for testing (`RestartAfter`, `SaveCapture`) are fine; flag anything new.
3. **Help matches the app.** The app is the source of truth. Compare what the app calls things with the website's help (`superhighfives.com/src/app/(markone)/mark-one/help/help-client.tsx`) and FAQ (`src/data/markone.ts`): settings names (`App/Views/SettingsView.swift`), menu window controls (`App/Views/MenuView.swift`), firmware window choices (`App/FirmwareView.swift`), and the welcome steps (`App/Views/WelcomeView.swift`). Fix the website to match and report what changed.
4. **Screenshots on the website.** Every picture on superhighfives.com/mark-one is a screenshot of the app, so retake them for each release:
   1. Retake the app's windows: `scripts/snapshot-app.sh` (a Debug build with a made-up camera, so no camera is needed). Windows flash up for a minute; tell the user to leave the mouse alone first. It fails while the screen is locked.
   2. The panel (`01-panel`) and the call (`02-call`) are live shots of the camera's picture. If the panel or the call looks different since the last release (`git diff PREVIOUS..HEAD --stat -- mac/MarkOne/App/Views/MenuView.swift`, or ask), ask the user to connect the camera and retake them: `swift scripts/capture-screenshots.swift 01-panel 02-call`. It waits for Return before each, so the user runs it (`! swift scripts/capture-screenshots.swift 01-panel 02-call`). Otherwise keep the last ones.
   3. Make the website's images: `scripts/website-screenshots.sh`. It lists the ones that changed, and any that changed size: change their `width` and `height` in `superhighfives.com/src/app/(markone)/mark-one/markone-client.tsx` to match, keeping the same scale as before (the panel and the call are shown at half size, the Updates tile at 0.8).
   4. Look at every changed image (decode with `dwebp`, then Read it) and check it shows what its `alt` text in `markone-client.tsx` says. Show the user the changed ones.
   5. Commit the retaken screenshots in this repo (`Mark One: Retake the app screenshots`) and push after confirming, so the release's tag includes them. In dry run mode, don't commit: the cleanup's reset discards them. The website's images go out with the changelog in Phase 5.

---

### Phase 3: Build and package

1. Build, export and notarize the app:
   ```sh
   scripts/build-release.sh
   ```
   In dry run mode, notarizing the app still runs (it's what lets the DMG's app open); only the DMG's notarization is skipped.
2. Copy the previous release's DMG for a delta (skip for the first release). It's in the releases repo:
   ```sh
   mkdir -p mac/MarkOne/build/release/VERSION/previous
   cp ~/Development/pika-workspace/releases/"Mark One"/PREVIOUS/Mark-One-PREVIOUS.dmg mac/MarkOne/build/release/VERSION/previous/
   ```
   If it's missing there, download it from the GitHub release instead (`gh release download PREVIOUS --repo superhighfives/mark-one --pattern 'Mark-One-*.dmg' --dir …`).
3. Run releasecast from the export folder:
   ```sh
   export PATH="$PWD/mac/MarkOne/build/SourcePackages/artifacts/sparkle/Sparkle/bin:$PATH"
   cd mac/MarkOne/build/release/export
   npx releasecast@0.0.13 "Mark One.app" -e hi@superhighfives.com -p mark-one -a mark-one \
     -t "RELEASE_TITLE" -r ../VERSION/previous -o ../VERSION
   ```
   Drop `-r …` for the first release. Add `-d` in dry run mode.
4. Check the output in `mac/MarkOne/build/release/VERSION/`: `Mark-One-VERSION.dmg`, `VERSION.md`, `appcast.xml`, and a `Mark-OneBUILD-FROM.delta` when there was a previous release.
5. Check the signature is Mark One's:
   ```sh
   SIG=$(sed -n 's/^signature: //p' mac/MarkOne/build/release/VERSION/VERSION.md)
   mac/MarkOne/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update --account mark-one --verify mac/MarkOne/build/release/VERSION/Mark-One-VERSION.dmg "$SIG"
   ```
   Stop if it fails: the installed app would refuse the update.
6. Live only: `spctl --assess --type open --context context:primary-signature --verbose` on the DMG says it's accepted (notarized).

---

### Phase 4: Release notes

The slow part is done; pause for the user.

1. Draft notes from the commits since the last release tag (`git log PREVIOUS..HEAD --oneline`, ignoring `notes:` commits), grouped like Pika's:
   1. **Overview paragraph**: what's in the release, in plain words.
   2. **Sign-off line**, exactly:
      ```
      As always, cheers for the support, and if you have any [issues or feedback, let me know on GitHub](https://github.com/superhighfives/mark-one/issues/new/choose).
      ```
   3. `### New features`: bullets, each starting with a bold label.
   4. `### Updates and bug fixes`: the same.
   Mention a new firmware revision when there is one (the camera offers the update over USB).
   If `MarkOneCamera`'s build number in `project.yml` went up since the last release tag, the notes must say the Mac may need a restart before the camera appears: Sparkle replaces only the app, and the new extension replaces the old one when Mark One next opens (NOTES.md, "Camera extension updates"). Don't go on to step 2 without that line.
2. Show the draft and ask the user to edit or approve it. The user writes the framing; don't publish notes they haven't seen.
3. Write `superhighfives.com/changelog/mark-one/VERSION.md`: releasecast's front matter from `VERSION.md`, then the notes. Show the whole file for a final review.

---

### Phase 5: Publish

Confirm before each step. In dry run mode, make the GitHub release a draft and skip the rest.

1. **GitHub release**, with the notes body (everything below the front matter):
   ```sh
   gh release create VERSION --repo superhighfives/mark-one --target main \
     --title "RELEASE_TITLE" --notes-file NOTES_FILE \
     mac/MarkOne/build/release/VERSION/Mark-One-VERSION.dmg \
     mac/MarkOne/build/release/VERSION/*.delta
   ```
   `--draft` in dry run mode. This also creates the tag.
2. **First release only:** set `available` to `true` in `superhighfives.com/src/data/markone.ts`, if the user wants the Download button live now.
3. **Website:**
   ```sh
   cd ~/Development/superhighfives.com
   git add changelog/mark-one/VERSION.md src/data/markone.ts public/assets/markone-*.webp "src/app/(markone)/mark-one/markone-client.tsx"
   git commit -m "Add changelog for Mark One VERSION"
   git push origin main
   ```
   It deploys on push; watch the run (`gh run list --workflow deploy.yml`).
4. **Check it's live:**
   - https://superhighfives.com/releases/mark-one/feed lists VERSION, with the GitHub URLs for the DMG and delta.
   - The DMG and delta URLs answer 200 (`curl -sIL`).
   - https://superhighfives.com/mark-one/download redirects to the DMG (once `available` is on).
5. **Homebrew** (live only). Nothing bumps the tap's cask by itself, so new
   installs would get the old version until it's updated. Check the
   published DMG's checksum matches the local one, then:
   ```sh
   SHA=$(curl -sL https://github.com/superhighfives/mark-one/releases/download/VERSION/Mark-One-VERSION.dmg | shasum -a 256 | cut -d' ' -f1)
   cd "$(brew --repo superhighfives/tools)"
   # set version "VERSION" and sha256 "$SHA" in Casks/mark-one.rb
   brew audit --cask superhighfives/tools/mark-one
   brew livecheck --cask superhighfives/tools/mark-one   # VERSION ==> VERSION
   git commit -am "Mark One VERSION"
   git -c credential.helper= -c credential.helper='!gh auth git-credential' push origin main
   ```
   The clone's HTTPS remote has no git credentials of its own, hence the
   one-off helper. Also bump the `mark-one` branch of
   `$(brew --repo homebrew/cask)`, kept as one `mark-one VERSION (new cask)`
   commit ready to submit, without checking it out:
   ```sh
   C="$(brew --repo homebrew/cask)"; W=SCRATCHPAD/cask-wt; OLD=$(git -C "$C" rev-parse mark-one)
   git -C "$C" worktree add -q --detach "$W" mark-one
   # set version and sha256 in "$W/Casks/m/mark-one.rb", then:
   git -C "$W" add Casks/m/mark-one.rb
   NEW=$(git -C "$W" commit-tree -S "$(git -C "$W" write-tree)" -p mark-one^ -m "mark-one VERSION (new cask)")
   git -C "$C" worktree remove --force "$W"   # it still holds the staged edit
   git -C "$C" update-ref refs/heads/mark-one "$NEW" "$OLD"
   ```
   Check `git -C "$C" rev-list --count mark-one^..mark-one` is 1. Once the
   cask is in Homebrew/homebrew-cask, Homebrew's autobump keeps it current
   from `livecheck`: drop this step then, and the tap's cask.

---

### Phase 6: Finalize

1. `git fetch --tags` and check the tag exists on the remote.
2. **File the release** in the releases repo (skip in dry run mode):
   ```sh
   R=~/Development/pika-workspace/releases/"Mark One"/VERSION
   mkdir -p "$R"
   cp mac/MarkOne/build/release/VERSION/{Mark-One-VERSION.dmg,VERSION.md,appcast.xml} "$R"/
   cp mac/MarkOne/build/release/VERSION/*.delta "$R"/ 2>/dev/null || true
   ditto -c -k --keepParent mac/MarkOne/build/release/MarkOne.xcarchive "$R/MarkOne-VERSION.xcarchive.zip"
   cd ~/Development/pika-workspace/releases
   git add "Mark One/VERSION" && git commit -m "Add release artifacts for Mark One VERSION" && git push origin main
   ```
   The archive has the debug symbols for reading crash reports from this build; the next build wipes `mac/MarkOne/build/release/`.
3. Add a dated line to `TODO.md` or `NOTES.md` only if something about the process changed or went wrong.
4. Summary checklist:
   - [ ] Version and build bumped and pushed (extension build: unchanged / bumped)
   - [ ] Firmware edits match the source
   - [ ] App notarized; DMG notarized and signed with Mark One's key
   - [ ] Delta made (or first release)
   - [ ] GitHub release and tag
   - [ ] Changelog on the website, deployed
   - [ ] Feed, DMG and download checked
   - [ ] Homebrew cask bumped (tap pushed; local homebrew-cask branch updated)
   - [ ] Release filed in the releases repo, with its archive
   - [ ] Website help matches the app
   - [ ] Website screenshots retaken (live shots: retaken / kept)

---

### Dry run cleanup

Only in dry run mode.

1. Undo the version bump commit (it wasn't pushed): `git reset --hard HEAD~1`, after checking that HEAD is that commit.
2. Remove `superhighfives.com/changelog/mark-one/VERSION.md` if it was written, and undo the screenshots there: `git checkout -- public/assets "src/app/(markone)/mark-one/markone-client.tsx"`.
3. Delete the draft release: `gh release delete VERSION --repo superhighfives/mark-one --yes --cleanup-tag`.
4. Leave `mac/MarkOne/build/release/` (gitignored) for inspection, or remove it if asked.

Report that the workspace is back where it started.
