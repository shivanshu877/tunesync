# TuneSync — Synchronized YouTube Music for macOS

**Date:** 2026-05-06
**Status:** Approved (brainstorming complete)
**Owner:** shivanshu@ivypods.com

## Goal

A native macOS app, written in Swift, that lets multiple Macs on the same Wi-Fi listen to the same YouTube Music track, perfectly in sync. Anyone in the room can play, pause, seek, or change the song — and everyone else's app follows within ~1 second. No servers, no accounts, no setup beyond launching the app.

## Non-goals (v1)

- No iOS / iPad client
- No internet relay (LAN only)
- No shared queue, chat, vote-skip, or moderation roles
- No room codes (one auto-room per Wi-Fi)
- No telemetry, analytics, or crash reporting
- No headless audio extraction (violates YT TOS)

## User stories

1. **Hosting**: Asha launches TuneSync on her MacBook. She signs into YouTube Music inside the app's WebView (one time; cookie persists). She plays a song. The status bar shows "0 peers — solo mode."
2. **Joining**: Bilal launches TuneSync on his Mac on the same Wi-Fi. Within ~3 seconds his app discovers Asha's via Bonjour and connects. His WebView jumps to the same track and timestamp Asha is playing. Both status bars now show "🟢 1 peer."
3. **Anyone controls**: Bilal pauses. Asha's app pauses within ~1 second. Bilal seeks to 2:30. Asha jumps to 2:30. Bilal clicks a different song in YT Music's UI. Asha's app loads the same song.
4. **Ad asymmetry**: Asha has Premium, Bilal does not. Bilal hits an ad mid-song. Asha keeps playing the song. When Bilal's ad ends, his player re-syncs to wherever Asha is in the song.
5. **Leaving**: Asha quits the app. Bilal's status bar drops to "0 peers — solo mode." Playback continues uninterrupted on Bilal's Mac.

## Architecture

```
┌─ TuneSync.app (one per Mac) ─────────────────────┐
│                                                   │
│  WKWebView (music.youtube.com, user's own login)  │
│      ▲                       │                    │
│      │ JS bridge             │ JS bridge          │
│      ▼                       ▼                    │
│  PlayerController                                 │
│    - readState() → {videoId, t, playing}          │
│    - applyState(...) → seek/play/pause/load       │
│      │                       ▲                    │
│      ▼                       │                    │
│  SyncEngine                                       │
│    - debounce local changes → broadcast           │
│    - receive peer updates → apply if newer        │
│    - LWW conflict resolution                      │
│      │                       ▲                    │
│      ▼                       │                    │
│  PeerMesh (Network.framework)                     │
│    - NWListener advertises _tunesync._tcp         │
│    - NWBrowser discovers peers                    │
│    - Maintains TCP connection per peer            │
└────────────────────────────────────────────────────┘
                  ▲
                  │ Bonjour/mDNS over Wi-Fi
                  ▼
            (other Macs running the app)
```

## Components

| Module | Responsibility | Key types |
|---|---|---|
| `App.swift` | App entry, single window, menu | `TuneSyncApp` |
| `WebViewHost.swift` | `NSViewRepresentable` wrapping `WKWebView`, sets up `WKUserContentController` and JS bridge | `WebViewHost`, `JSBridge` |
| `PlayerController.swift` | Reads/writes YT Music state via injected JS | `PlayerState`, `PlayerController` |
| `SyncEngine.swift` | Local change → debounce → broadcast; remote update → apply with suppression | `SyncEngine`, `SyncMessage`, `LamportClock` |
| `PeerMesh.swift` | `NWListener` + `NWBrowser` + per-peer `NWConnection`; framed TCP I/O | `PeerMesh`, `Peer`, `Frame` |
| `StatusBar.swift` | SwiftUI strip at bottom of window: peer count, room, last writer | `StatusBar` |
| `injected.js` | Runs inside WebView. Hooks `<video>` events, exposes `applyState()`, detects ads. | (resource file) |
| `Logger.swift` | Single OSLog wrapper | `Log` |

## Data flow

### Outbound (local user does something in YT Music UI)

1. Injected JS hooks `<video>` element events: `play`, `pause`, `seeked`, `ratechange`, `loadedmetadata`.
2. JS posts `{kind: "state", videoId, t, playing, ts}` to native via `webkit.messageHandlers.tunesync.postMessage(...)`.
3. `PlayerController` debounces 200 ms (collapse rapid scrub events) and forwards to `SyncEngine`.
4. `SyncEngine` stamps `senderId` + monotonic `ts`, encodes JSON, sends to all peers via `PeerMesh`.

### Inbound (peer sent us an update)

1. `PeerMesh` receives a length-prefixed JSON frame.
2. `SyncEngine` checks `(ts, senderId) > lastApplied`. If not strictly newer, drop.
3. `SyncEngine` sets a 500 ms suppression flag (so the resulting JS-driven `play`/`pause` events don't echo).
4. `PlayerController.applyState()` runs JS:
   - If `videoId` differs from current → call YT Music's player API to load the new video at offset `t`.
   - Else if `|local.t − remote.t| > 1.5 s` → seek.
   - If `playing` differs → call `play()` or `pause()`.
5. Suppression flag clears after 500 ms.

### Frame format on the wire (TCP, length-prefixed)

```
[uint32 len, big-endian][JSON bytes]
```

```json
{
  "kind": "state",
  "senderId": "550e8400-e29b-41d4-a716-446655440000",
  "ts": 1730000000000,
  "videoId": "dQw4w9WgXcQ",
  "t": 47.2,
  "playing": true
}
```

Other frame kinds: `hello` (initial handshake with `senderId` + display name), `bye` (graceful close).

## Sync rules

- **Last-writer-wins** by `(ts, senderId)` lexicographic comparison.
- **Drift threshold**: only seek if remote.t differs from local by > 1.5 s. Below that, ignore — natural clock drift between Macs is fine.
- **Heartbeat**: every 5 s, each peer broadcasts its current state. Catches up newly-joined peers and corrects accumulated drift.
- **Ad detection**: injected JS reads `document.querySelector('.ytmusic-player-bar')?.classList.contains('ad-showing')` as primary, with fallback selectors. While ad is showing, the local app suppresses outbound state and ignores inbound seek (still applies play/pause). When ad ends, request a fresh heartbeat and re-sync.
- **`senderId`**: per-launch UUID. Not persisted across runs.
- **Display name**: hostname (`Host.current().localizedName ?? "Mac"`).

## Edge cases

| Case | Handling |
|---|---|
| User not logged into YT Music | WebView shows YT login page; sync engine waits for `videoId` to appear. Status bar reads "🔒 sign in to YT Music." |
| YT Music DOM changes (they update the site) | All selectors centralized in `injected.js`. Each has a fallback. If all selectors miss for 30 s, log a warning and disable sync until next page load. |
| Peer disconnects mid-song | `NWConnection.stateUpdateHandler` removes peer from list; status bar updates count. No effect on local playback. |
| Two users hit play within 100 ms | LWW by `ts`. With 200 ms debounce + 5 s heartbeat, converges within 5 s. |
| User on Premium, peer on free → ads | Ad-suppression rule above. Non-ad user keeps playing; ad user catches up after ad. |
| App launched but Wi-Fi off | `NWBrowser` returns no peers; UI shows "🟡 0 peers — solo mode." |
| Two Macs with same hostname | We use a per-launch UUID as `senderId`, not hostname. Display name disambiguation is best-effort (hostname + last 4 of UUID if conflict). |
| YouTube redirects WebView outside `music.youtube.com` | Navigation delegate blocks navigation to non-`youtube.com` hosts; `accounts.google.com` allowed for login flow. |
| WKWebView blocks autoplay | We use `WKWebViewConfiguration.mediaTypesRequiringUserActionForPlayback = []` and rely on the user's first explicit play gesture, then sync follows. |
| Sandbox / network entitlements | App Sandbox enabled with `com.apple.security.network.server`, `com.apple.security.network.client`, and Bonjour service `_tunesync._tcp` declared in Info.plist. |

## Testing strategy

### Unit (XCTest, runnable in CI)

- `SyncEngineTests`: LWW ordering, debounce coalescing, ad-suppression behaviour, heartbeat tick, suppression-flag echo prevention.
- `FrameCodecTests`: round-trip encode/decode, oversize rejection, partial-buffer handling.
- `LamportClockTests`: monotonicity, tie-breaking by senderId.

### Integration (manual, two-Mac)

Two Macs on same Wi-Fi:
- Discovery within 5 s of second Mac launching
- Play/pause syncs within 1.5 s
- Seek syncs within 1.5 s
- Track change syncs within 3 s (loading time dominates)
- Ad on free account doesn't pause the Premium peer
- Closing one app cleanly removes peer from the other's list within 5 s

### Single-Mac smoke test (what the AI can verify)

- App launches without crashing
- WebView loads `music.youtube.com`
- Bonjour service advertises (verify with `dns-sd -B _tunesync._tcp`)
- JS bridge round-trip works (inject, read state, log)
- Unit tests pass under `swift test`

## Project layout

```
TuneSync/
├── Package.swift
├── README.md
├── docs/
│   └── superpowers/
│       ├── specs/2026-05-06-tunesync-design.md   ← this file
│       └── plans/                                 ← implementation plan goes here
├── Sources/
│   └── TuneSync/
│       ├── App.swift
│       ├── WebViewHost.swift
│       ├── PlayerController.swift
│       ├── SyncEngine.swift
│       ├── PeerMesh.swift
│       ├── StatusBar.swift
│       ├── Logger.swift
│       ├── Models.swift
│       └── Resources/
│           └── injected.js
└── Tests/
    └── TuneSyncTests/
        ├── SyncEngineTests.swift
        ├── FrameCodecTests.swift
        └── LamportClockTests.swift
```

## Build & run

- Swift Package with executable target `TuneSync`.
- `swift build -c release` produces `.build/release/TuneSync` (raw binary).
- A small `Makefile` wraps `.app` bundling: copies binary into `TuneSync.app/Contents/MacOS/`, writes Info.plist with Bonjour entitlements, copies `injected.js` into `Resources/`.
- Run with `make run` or open `TuneSync.app`.

## Out of scope for v1, queued for later

| Future feature | When |
|---|---|
| Room codes (multiple rooms per LAN) | v1.1 — Approach 2 from brainstorm |
| Internet relay fallback | v2 — when "different Wi-Fi" requests come in |
| Shared queue + vote-skip | v2 — only if users ask |
| Browser-control mode (Approach B) | v3 — fallback for users who don't want a WebView |
| iOS companion (control-only) | v3 |
| Code signing + notarization | before public distribution |

## Open risks

1. **YT Music DOM is undocumented** — selectors may break with their UI updates. Mitigation: centralize selectors, log warnings, fall back to native `<video>` element where possible (which is much more stable).
2. **Apple may block the WKWebView's audio playback** under future App Sandbox tightening. Mitigation: standard WKWebView audio is well-supported; only an issue if Apple changes policy.
3. **Two Macs with very different network latency** could see >1 s sync gaps. Mitigation: heartbeat catches it within 5 s; acceptable for non-DJ use.
4. **YT Music TOS** — controlling someone's playback via injected JS in their own browser-equivalent is roughly equivalent to what the user does manually. Lower risk than headless extraction. We don't redistribute audio.
