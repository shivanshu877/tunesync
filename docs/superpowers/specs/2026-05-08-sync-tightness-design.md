# Sync Tightness — Design

Status: draft
Date: 2026-05-08
Depends on: rooms-reliability spec (uses its `.ping` / `.pong` for clock estimation)
Scope: tighten cross-Mac playback alignment from "within ~1 s" to "within ~150 ms steady-state".

## Problem

Two Macs in the same room hear audible offset on track start and on seek. Sources:

1. No cross-Mac clock sync. Latency-compensation uses peer's `clientMs` minus local `Date.now`, which conflates network RTT with wall-clock skew.
2. Seek threshold in `InjectedJS` is `1.0 s`. Drift below that is never corrected.
3. State is applied "as fast as possible" on receive — but YouTube Music's audio decoder warmup adds a variable 100–400 ms lag before sound starts, so the leader and follower diverge by exactly that warmup.
4. No drift correction for slow accumulating skew (audio clock vs. wall clock).

## Goals

- Steady-state offset between two Macs ≤ 150 ms after a track is established (≥ 5 s playing).
- Offset on track-change ≤ 300 ms (one-time alignment).
- Offset on seek ≤ 200 ms.
- No audible jitter from over-correction.

## Non-goals

- Frame-accurate sync. Audio decoder warmup is not deterministic on YT Music.
- Sub-100 ms offset. Would need a custom audio pipeline.
- Sync across bad networks (high-jitter Wi-Fi). Best-effort.

## Architecture

Three coordinated mechanisms:

### 1. Clock-offset estimator (in `PeerMesh` / new `ClockSync`)

Reuses `.ping` / `.pong` from rooms-reliability spec. Each ping carries `t0 = sender wallclock`. Pong echoes back with `t1 = receiver wallclock at receive` and `t2 = receiver wallclock at send`. Sender computes:

- `RTT = (now - t0) - (t2 - t1)`
- `offset = ((t1 - t0) + (t2 - now)) / 2`  (NTP-style)

Maintain a 5-sample sliding window per peer; use the sample with the lowest RTT (best estimate). Expose `peerOffsetMs(senderId:)` from `PeerMesh` to `SyncEngine`.

### 2. Scheduled apply (`SyncEngine` + `InjectedJS`)

Outgoing `StateMessage` gains `applyAtMs`: a wallclock target time on the *sender's* clock when they expect the state to take effect. Default: `clientMs + 300` (gives followers a 300 ms budget to receive and prepare).

Receiver translates `applyAtMs` to local clock via `peerOffsetMs`, then schedules the apply:

- If `targetLocalMs - now` is between 0 and 1000 ms, schedule via `setTimeout`.
- If outside that window, apply immediately (clock estimate is unreliable; fall back to current behavior with latency comp).

`tunesyncApplyState` gains an `atMs` arg. When provided, it sets `currentTime` to `t + (atMs - now)/1000` if currently playing, or schedules play at `atMs`.

### 3. Soft drift correction

Lower the JS seek threshold from `1.0 s` to:

- **`0.5 s`** → hard seek (`v.currentTime = t`).
- **`0.05 s` to `0.5 s`** → soft correction via `v.playbackRate`. Set rate to `1.02` (catch up) or `0.98` (slow down) until error < 30 ms, then restore `1.0`. Audible nudge < 2% is below most listeners' threshold.
- **`< 0.05 s`** → ignore.

Drift correction runs only when `role == .guest` and a recent host state has been applied. Host never self-corrects.

## Wire protocol delta

`StateMessage` adds optional `applyAtMs: Int64?`. Older peers ignoring the field still work — they apply immediately as today, and the sender's compensation falls back gracefully.

`PingMessage` / `PongMessage` (from rooms-reliability) carry `t0`, `t1`, `t2`.

## Data flow

```
host: localStateChanged → SyncEngine builds StateMessage
                          with applyAtMs = clientMs + 300
                       → broadcast
guest: receive → SyncEngine
                 ↳ translate applyAtMs via offset
                 ↳ schedule applyState at local target
                 ↳ JS sets currentTime + plays at target
                 ↳ on next tick, soft-correct drift via playbackRate
```

## Components

- `Sources/TuneSyncCore/ClockSync.swift` (new). Pure-logic offset estimator; takes `(t0, t1, t2, now)` samples, returns offset + RTT. Unit-testable without network.
- `Sources/TuneSyncCore/SyncEngine.swift`. Schedule logic; expose tunable `applyLeadMs` (default 300).
- `Sources/TuneSyncCore/Models.swift`. `StateMessage.applyAtMs` field.
- `Sources/TuneSync/InjectedJS.swift`. `tunesyncApplyState(videoId, t, playing, atMs)`; soft-correction loop.

## Testing

### Unit

- `ClockSyncTests` — given canned ping/pong samples, verify offset and RTT within tolerance; window picks lowest-RTT sample.
- `SyncEngineScheduleTests` — `StateMessage` with `applyAtMs` future schedules; past applies immediately.
- `InjectedJS` — pure-JS unit harness already exists? If not, manual test only.

### Manual two-Mac

Add to `docs/TESTING.md`:

1. Start track on host, measure offset by ear (or two phones recording). Target ≤ 300 ms on track start.
2. Let play 60 s. Measure steady-state offset. Target ≤ 150 ms.
3. Seek host to 1:30. Target ≤ 200 ms within 2 s of seek.

### Diagnostics

Diagnostics panel adds:

- Per-peer estimated offset ms, RTT ms.
- Last-applied scheduled-vs-actual delta (how late did we miss the target?).
- Soft-correction state (`rate=1.02`, `rate=1.0`, etc).

## Rollout

Single PR after #4 lands. Wire protocol change is additive (optional fields). Bump to `0.2.9`.

## Out of scope / follow-ups

- Audio decoder warmup measurement and pre-prediction. Possible later by sniffing first-`canplay` lag and feeding it back into `applyLeadMs`.
- Per-peer adaptive `applyLeadMs` based on observed RTT variance.
