# Doctor Mac

A release cockpit for shipping macOS apps. Doctor Mac scans your projects folder, then builds, signs, packages, notarizes, staples, and publishes any of them from one window — and tells you *why* a step failed in plain English instead of dumping a wall of xcodebuild output.

**[Download the latest release](https://github.com/kartikk-k/Doctor-Mac/releases/latest)** — signed & notarized DMG.

## Why

Shipping a Mac app outside the App Store is a chain of fussy commands (`xcodebuild archive`, `-exportArchive`, `hdiutil`, `notarytool`, `stapler`, `spctl`, `gh release`), and a mistake early in the chain surfaces minutes later as a cryptic error. Doctor Mac's job is knowing why those commands fail and fixing them before they run.

## Features

- **Full pipeline** — Archive → Export (Developer ID) → DMG → Notarize → Staple → Verify, with optional GitHub Release publishing and Sparkle appcast updates. Live logs, per-stage timing, retry / resume-from-here.
- **Preflight checks gate the run button** — toolchain, shared scheme, signing identity (incl. certificate expiry), Team ID match, notarization key, provisioning-profile mismatches, duplicate bundle IDs, dirty git tree, disk space. Every failure has a one-click fix where one exists.
- **Errors explained** — failed stages expand with the parsed cause, a suggested fix, and the relevant log slice (e.g. *"resource fork, or similar detritus" → run `xattr -cr` on the app*).
- **Result card** — DMG size, SHA-256, notarization status, submission ID, and a ready-to-paste release-notes block.
- **Credentials manager** — App Store Connect API keys become `notarytool` keychain profiles (the `.p8` secret lives in the Keychain, not on disk or in this repo), plus GitHub CLI auth status and Sparkle EdDSA key setup.
- **TCC permission resets** — reset Accessibility, Microphone, Screen Recording, etc. for any managed app via `tccutil` while iterating.

## CLI

The app binary doubles as a headless CLI that shares the app's configuration — set up projects and credentials in the window once, then drive releases from a terminal or CI:

```sh
# one-time: symlink to /usr/local/bin/doctor-mac
"/Applications/Doctor Mac.app/Contents/MacOS/Doctor Mac" install-cli

doctor-mac list                        # managed projects and versions
doctor-mac preflight "My App"          # same checks as the run button; exit 1 on failure
doctor-mac release "My App"            # archive → export → dmg → notarize → staple → verify
doctor-mac release "My App" --publish  # …then create the GitHub release and upload the DMG
doctor-mac release "My App" --from notarize   # resume from a stage
```

`release` refuses to start if preflight fails (override with `--force`) and prints a per-stage summary with cause + fix on failure.

## Requirements

- macOS with full Xcode installed (the app lets you pick the `DEVELOPER_DIR`)
- A **Developer ID Application** certificate in the keychain for signing
- An App Store Connect **API key** (`.p8`) for notarization
- [`gh`](https://cli.github.com) (authenticated) for publishing, [Sparkle](https://sparkle-project.org) tools for appcasts — both optional

## Building from source

```sh
git clone https://github.com/kartikk-k/Doctor-Mac.git
cd Doctor-Mac
xcodebuild -project "Doctor Mac.xcodeproj" -scheme "Doctor Mac" -configuration Release build
```

Configuration is stored as JSON at `~/Library/Application Support/DoctorMac/state.json` — references only, never secrets.
