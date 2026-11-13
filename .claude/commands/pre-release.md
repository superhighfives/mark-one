# Pre-Release

A quick hygiene check to run before `/release`, while things can still be
fixed and committed. Read-only: it reports, and offers a fix only where the
fix is obvious. Modelled on Pika's `/pre-release`.

Supports flags via `$ARGUMENTS`:
- `--fix` — offer to fix mechanical issues (never version numbers, never
  release notes).

## Instructions

Run every check, then show one summary table (check, result, detail). Don't
stop at the first failure.

Read `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from
`mac/MarkOne/project.yml` for context. `/release` owns the version bump.

### 1. Clean tree

- `git status --porcelain` in this repo: anything uncommitted or untracked is a **fail** (list it).
- On `main` and not behind `origin/main`.

### 2. Leftovers in code

Search `mac/MarkOne/` (Swift) and `scripts/`:

- `TODO`, `FIXME`, `XXX`, `HACK` added since the last release tag (`git diff TAG..HEAD`). Older ones are fine; mention the count.
- `print(` or `NSLog(` in Swift: Mark One logs through `Logger`. **Fail** on new ones.
- `UserDefaults` keys that exist only for testing. Known and documented: `RestartAfter`, `SaveCapture`. Anything else new is a **warning**.
- Constants changed for testing are back at their documented values (for example `Pipeline.restartTime`, 100 minutes).

### 3. Firmware

- `WEBCAM_REVISION` in `scripts/build.py` matches `"revision"` in `mac/MarkOne/App/Resources/webcam-firmware.json`.
- If any `asm/` or `scripts/build.py` file changed since the last tag, the JSON changed too (otherwise the app ships stale edits). `/release` does the full rebuild check.
- If the revision went up since the last tag: the notes for this release should mention the camera update.

### 4. Builds

- The Debug build compiles with no warnings in `App/` or `Extension/`:
  ```sh
  cd mac/MarkOne && xcodebuild -project MarkOne.xcodeproj -scheme MarkOne -configuration Debug -derivedDataPath build build 2>&1 | grep -E "warning:|error:" | grep -v appintents
  ```
- `uv run --frozen scripts/build.py --roundtrip fw/OLY_E_097_2300_0000_0000.BIN` passes (needs `fw/`).

### 5. Website

In `~/Development/superhighfives.com`:

- Clean apart from `bun.lock`, on `main`, up to date.
- `node_modules/.bin/biome check src` passes.
- The help page's settings and menu names still match the app (the full comparison is in `/release`, Phase 2; here just flag obvious drift since the last tag).

### 6. Open items

- List unchecked items in `TODO.md` under "Before launch" (or the current release's section) so the user can decide whether any block this release.

### Out of scope

Version numbers, the build, notarization, release notes, the GitHub
release and the website deploy all belong to `/release`.
