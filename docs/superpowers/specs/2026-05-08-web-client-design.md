# Web Client — Design

Status: draft
Date: 2026-05-08
Depends on: rooms-reliability (#4), sync-tightness (#5)
Scope: a browser-based TuneSync client that joins the same LAN room as the Mac apps and plays in sync. Phones, iPads, Linux laptops, anything with a modern browser.

## Problem

Mesh today is Bonjour + raw TCP frames + native `NWConnection`. Browsers can't do any of that — no mDNS, no raw TCP. So a non-Mac device can't join. Adding a web client opens TuneSync to every device on the LAN.

## Goals

- Open `http://<mac-ip>:8732` (or scan a QR) on any device → joins room, plays in sync.
- Same sync semantics as Mac client (host / guest, applyAt scheduling).
- No accounts. No internet round-trip beyond fetching the YT Music embed.
- Survive room name changes, leader switches, peer churn.

## Non-goals

- Web client controlling the Mac client's player (initially; can add later).
- WAN / cross-LAN. Same-LAN only.
- Native iOS / Android — the web client serves that need.

## Architecture

A Mac client elects itself **bridge**: it runs an embedded HTTP + WebSocket server on a fixed port (default 8732) and translates between WebSocket-speaking browsers and the existing `PeerMesh` TCP frames. The bridge participates in the mesh as a normal peer. Web clients are mesh peers *via* the bridge.

```
   Web client ─WS──┐
                   ├─► Bridge Mac ─PeerMesh TCP──► Mac client
   Web client ─WS──┘                            └─► Mac client
```

### Why bridge, not direct WebRTC

WebRTC is the obvious "browsers as full peers" answer, but it requires a signaling channel. Without an internet server, signaling has to come from the LAN — which means a Mac is already running an HTTP server for signaling. Once we have that server, sending sync frames over WebSocket is simpler and lower-latency than negotiating an SCTP data channel for control messages. WebRTC can be added later if we want browser-to-browser audio routing, which we don't.

### Bridge election

Any Mac can be the bridge. Election rule: lowest `senderId` among Macs in the room. If the bridge leaves, next-lowest takes over. Web clients reconnect to the new bridge (advertised via Bonjour TXT record `bridge=1`).

### Bonjour for web discovery

The bridge publishes `_tunesync-bridge._tcp` with TXT `room=<name> port=8732`. Web client doesn't see this directly (no mDNS in browsers), but a captive landing page at the bridge URL renders a "join room <X>" page after a manual URL/QR-code visit.

## Wire protocol

WebSocket frames are JSON, same `SyncMessage` cases as TCP mesh, plus:

- `welcome` — bridge sends to a new web client: room name, peer list, current host's last state.

The bridge fans out incoming WebSocket `state` messages to all mesh peers (Mac + other web), and vice versa. From the engine's standpoint, a web client is just another peer.

## Web client code

Static SPA, served by the bridge.

- HTML loads YT Music in an `<iframe>` at `https://music.youtube.com/watch?v=<id>` — same trick as the Mac WebView.
- Same `InjectedJS` logic, but injected via a `postMessage` shim because we can't run scripts inside cross-origin iframe. Browsers block that.

**Iframe limitation discovered:** YT Music sets `X-Frame-Options: SAMEORIGIN`, which blocks our iframe entirely. Two options:

- **Web Audio fallback:** the web client doesn't render YT Music UI. It uses YT iframe API (`https://www.youtube.com/embed/<id>?enablejsapi=1`), which *is* embeddable, then drives `play / pause / seekTo` via the postMessage API. Loses the YT Music UI but gains sync.
- **Server-side audio extraction:** out — not feasible legally.

Recommendation: embeddable YT iframe API. The web client UI is "now playing" + a small playlist queue + transport controls, not the full YT Music shell.

## Components

### Mac side (bridge)

- `Sources/TuneSyncCore/Bridge.swift` — HTTP + WebSocket server. Stand-alone class, used only when this Mac is the bridge.
- `Sources/TuneSyncCore/PeerMesh.swift` — emit bridge claim in TXT record; track which peer is bridge.
- `Sources/TuneSync/StatusBar.swift` — show "bridging N web clients".
- Bundle web SPA assets via `Resources/Web/` and serve from memory.

### Web SPA (`Resources/Web/`)

- `index.html`, `app.js`, `style.css`. Tiny, no framework — keeps DMG size low and load fast.
- YT iframe API integration. Sync engine reimplemented in JS, sharing semantics with the Swift one.

## Sync semantics

Web client receives `state` with `applyAtMs`. JS schedules `setTimeout(applyAtMs - now)` and calls `player.seekTo(t)` + `player.playVideo()`. Same drift correction via `setPlaybackRate`. Clock-offset estimated via WebSocket-level ping/pong.

WebSocket RTT on LAN is typically < 5 ms; sync should be as good as Mac-to-Mac.

## Security

LAN-only. No auth: matches existing trust model. CSRF not relevant — no cross-site requests. Bind server to non-loopback so LAN reaches it; document the firewall prompt on first run.

## Testing

### Unit

- `BridgeTests` — WebSocket messages map to `SyncMessage` and back; bridge fans out correctly.
- Election test — lowest senderId wins; on leader leave, next takes over.

### Manual

1. Mac running TuneSync. Open `http://<mac-ip>:8732` on iPhone Safari. Joins room. Plays the same track.
2. Two Macs + one phone. Phone hears same audio aligned within 200 ms.
3. Bridge Mac quits. Phone reconnects to next Mac within 5 s.

## Rollout

Largest PR of the five. Land on its own branch. Bump to 0.4.0. README + landing site updated with QR-code instructions.

## Out of scope / follow-ups

- Native iOS / Android wrappers.
- Browser-to-browser WebRTC routing.
- HTTPS with a self-signed cert (some browsers require HTTPS for some APIs; fine without for now since we don't use them).
- Auth tokens for "private" rooms.
