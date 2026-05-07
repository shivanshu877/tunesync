# TuneSync

Sync YouTube Music playback across multiple Macs on the same Wi-Fi. No servers, no accounts (beyond each user's own YouTube Music login), anyone in the room can control playback.

## Install

Download the latest DMG from the [releases page](https://github.com/shivanshu877/tunesync/releases) (or the [downloads site](https://shivanshu877.github.io/tunesync/)), drag `TuneSync.app` to `/Applications`.

First launch on a fresh Mac, macOS will say *"cannot be opened because the developer cannot be verified."* Right-click the app → **Open** → **Open**. After that, double-click works normally.

If macOS keeps blocking it:

```bash
xattr -dr com.apple.quarantine /Applications/TuneSync.app
```

The app will also ask for **Local Network** access on first run — approve it, that's how peers discover each other.

## Auto-updates

The app checks the published manifest at `https://shivanshu877.github.io/tunesync/updates.json` 30 seconds after launch and every 6 hours. When a newer version is published, an alert appears with a Download button. Manual check: **TuneSync menu → Check for Updates… (⌘U)**.

## Develop

```bash
swift build           # debug build
swift test            # run unit tests
swift run TuneSync    # run dev binary
make bundle           # build TuneSync.app
make dmg              # ad-hoc-sign + build DMG
make run              # bundle + open
```

Project layout: `Sources/TuneSyncCore/` is a testable library (sync engine, peer mesh, frame codec); `Sources/TuneSync/` is the executable (SwiftUI shell, WebView, updater).

See `docs/superpowers/specs/2026-05-06-tunesync-design.md` for design.

## Cut a release

Tag the commit and push:

```bash
git tag v0.2.5
git push origin v0.2.5
```

GitHub Actions will:

1. Run tests
2. Build the DMG with the tag's version baked into the Info.plist
3. Create a GitHub Release with auto-generated notes
4. Publish the DMG + `updates.json` to the `gh-pages` branch
5. Existing TuneSync installs see the update on their next 6-hour poll

## Two-Mac integration test

See [`docs/TESTING.md`](docs/TESTING.md).
