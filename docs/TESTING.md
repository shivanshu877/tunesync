# Two-Mac integration test

The unit tests cover the core sync engine, Lamport clock, frame codec, and message round-trip. Multi-Mac sync **cannot** be verified by automation — it needs two real Macs on the same Wi-Fi.

## Prereqs

- Two Macs on the same Wi-Fi
- macOS 14+ on both
- The `TuneSync.app` bundle built via `make bundle` (or copied between Macs after building once)
- Each Mac signs into YouTube Music in the app's WebView the first time it's launched (cookies persist)

## Test sequence

1. **Mac A**: launch `TuneSync.app`. Sign into YouTube Music. Play any song.
   - Status bar should read "🟡 0 peers · solo mode" until Mac B joins.

2. **Mac B**: launch `TuneSync.app`. Sign into YouTube Music.
   - Within ~5 s, both Macs' status bars should read "🟢 1 peer".
   - Mac B's WebView should jump to the same song Mac A is playing, at roughly the same position.

3. **Pause test**: pause on Mac A. Mac B should pause within 1.5 s.

4. **Seek test**: drag the playhead on Mac B to a new spot. Mac A should follow.

5. **Track-change test**: click a different song on Mac A (search or click in queue). Mac B should load and play the same song.

6. **Ad test** (only if one Mac is non-Premium): when an ad starts on the non-Premium Mac, the Premium Mac should NOT pause. When the ad ends, the non-Premium Mac re-syncs.

7. **Disconnect test**: quit on Mac A. Mac B's status bar should drop to "🟡 0 peers" within 5 s. Playback continues on Mac B.

## If sync doesn't happen

- Run `dns-sd -B _tunesync._tcp local.` on each Mac while the app is running. Each Mac should see itself AND the other.
- Check Console.app filtered to subsystem `com.tunesync.app` for errors:
  ```bash
  log stream --predicate 'subsystem == "com.tunesync.app"' --info --debug --style compact
  ```
- Some networks (corporate, "guest" Wi-Fi, public hotspots) block mDNS/Bonjour client isolation. Try a home Wi-Fi or personal hotspot.
- The first time each app runs on macOS 14+, the OS will prompt for "local network" access. Approve it (matches the `NSLocalNetworkUsageDescription` in Info.plist).

## What's known to be flaky

- **Track-change on macOS Sonoma+ may briefly mute** — the WebView re-navigates when the videoId changes (we use `window.location.href` rather than YT's internal player API). Workaround: it autoplays after navigation; just wait ~1 s.
- **YT Music DOM may shift selectors** — if peer count is right but no state syncs, YT updated their UI. Edit `Sources/TuneSync/Resources/injected.js` selectors.
