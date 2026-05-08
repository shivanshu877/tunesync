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

## Reliability scenarios (post 0.2.8)

These require two Macs on the same Wi-Fi.

### Wi-Fi reassociation

1. Both Macs in same room. Verify peer list shows each other.
2. On Mac B: turn Wi-Fi off, wait 5s, turn back on (same SSID).
3. Within ~10s of reassociation, both peer lists should show the partner again.
4. Diagnostics: `Restarts P:` should have incremented on Mac B.

### Sleep / wake

1. Both Macs connected.
2. Sleep Mac B for 2 minutes.
3. Wake Mac B.
4. Within 10s, both peer lists should show each other. No app restart needed.

### Room rename

1. Mac A and B both in room `default`.
2. Mac A renames room to `kitchen`.
3. Mac B's connected list clears within 1–2s.
4. Mac B renames to `kitchen`.
5. Both reconnect within 5s. No ghost entries from `default`.

### Kick + reconnect

1. Mac A kicks Mac B.
2. Mac B should drop from Mac A's connected list, appear in discovered.
3. On Mac A, click "reconnect" for Mac B.
4. Single connection re-established. No duplicate entry.

### Liveness timeout

1. Both connected.
2. On Mac B: in Activity Monitor, force-kill TuneSync (don't quit gracefully — skip the bye).
3. Mac A's peer list should drop Mac B within ~25s (no `bye` received, ping timeout fires).
4. Diagnostics: `Ping timeouts` increments by 1.

## Sync tightness scenarios (post 0.2.9)

Two Macs same Wi-Fi, both signed into YT Music.

### Track-start alignment

1. Mac A (host) plays a fresh track.
2. Listen for offset between Macs by ear (or record both speakers on a phone).
3. Target: ≤ 300 ms.

### Steady-state drift

1. Both Macs playing same track, host driving.
2. Let play 60 s without interaction.
3. Target: offset stays ≤ 150 ms (no audible drift).
4. Diagnostics should show non-zero `off:` per peer (NTP offset in ms).

### Seek

1. Host seeks to 1:30.
2. Within 2 s, guest is at 1:30 ± 200 ms.

### Ad on host

1. Wait for an ad on host (or sign out so YT serves ads).
2. Guest's TuneSync should mute + pause within 1 s of ad start.
3. When ad ends, guest unmutes and resumes in sync.

## Anonymous-playback scenarios (post 0.2.10)

### Cold start, no sign-in

1. Clear app data: `rm -rf ~/Library/WebKit/TuneSync ~/Library/Caches/TuneSync` then relaunch.
2. Launch. App lands on YT Music home.
3. No sign-in modal blocks the view (it may briefly flash, but disappears).
4. Top of window shows a search bar.

### Search and play

1. Type "lofi" in the search bar; press Enter.
2. WebView navigates to a YT Music search result page.
3. Click any track. Plays without a sign-in prompt.

### Two Macs, neither signed in

1. Both Macs on same Wi-Fi, both signed-out.
2. Mac A plays a track via search. Mac B receives state and plays the same track in sync.
