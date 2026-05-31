# Wall-clock scheduled play, clock-offset aware

**Status:** draft
**Date:** 2026-05-31
**Owner:** prateek

## Problem

When a user hits play on the host Mac, the host broadcasts a "scheduled play" message containing `startAtMs` (host wall-clock + 3000 ms buffer). Both host and receivers are supposed to pre-pause, pre-seek, and fire `play()` at that exact wall-clock instant — so every peer starts together.

In practice, the receiver Mac plays the song immediately while the host correctly waits the full 3 seconds. Net effect: the receiver appears ~3 s ahead of the host.

Root cause: `SyncEngine` compares the host's `startAtMs` directly against the receiver's `Date()` without any clock-offset correction. Any non-trivial skew between the two Macs' wall-clocks pushes `isScheduled` to `false` on the receiver, so the receiver forwards `nil` to the player and plays immediately.

`ClockSync` already measures per-peer offsets via the mesh ping/pong path (used today only in mesh diagnostics). The native `SyncEngine` never reads them. The web bridge client does its own ping/pong and is unaffected.

## Goal

Make scheduled play a **pure wall-clock event** in the model the user described:

> "Send a time to all the players attached to it for when to start playing. If I click play at 9:51:020, the event will also carry when to start playing — for example 9:51:080."

Every peer (host and receivers) waits for that single wall-clock instant and fires `play()` there. No elapsed-time math, no rate-bending, no `t` adjustment. Clock skew is corrected once, at apply time, using the existing per-peer NTP-style offset.

Shorten the buffer from 3000 ms → **800 ms** now that offset is honored.

## Non-goals

- Changing the broadcast / heartbeat / suppression model.
- Reworking the web bridge client (already wall-clock correct after the previous PR).
- Implementing a new clock-sync algorithm — reuse `ClockSync` as-is.

## Design

### Data flow

1. Host hits play. `flushDebounce` builds a state message with `startAtMs = hostNow + scheduleBufferMs` (host wall-clock).
2. Host applies locally with that same `startAtMs` (its own clock = canonical → no offset).
3. Mesh broadcasts the message.
4. Receiver decodes, calls `SyncEngine.handleRemote → apply`.
5. `apply` looks up `offsetMs = clockOffsetMsFor(senderId)` and computes
   `localStartAt = startAtMs - offsetMs`.
6. `isScheduled = localStartAt > nowMs` (now compared in the same clock frame).
7. `applyStateImpl` receives `localStartAt` (not raw `startAtMs`) and forwards it to JS.
8. JS pre-pauses, pre-seeks, schedules `setTimeout(play, localStartAt - Date.now())`.

### Components & interfaces

**`SyncEngine.init`** gains:

```swift
clockOffsetMsFor: @escaping (_ senderId: String) -> Int = { _ in 0 }
```

Default no-op preserves existing unit-test ergonomics.

**`SyncEngine.apply`** (receive branch) updates the schedule arithmetic:

```swift
let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
let offsetMs = Int64(clockOffsetMsFor(s.senderId))
let localStartAt = (s.startAtMs ?? 0) - offsetMs
let isScheduled = localStartAt > nowMs
```

`applyStateImpl` is called with `isScheduled ? localStartAt : nil` (note: `localStartAt`, not the raw `s.startAtMs`).

The post-fire suppression window also keys on `localStartAt`:

```swift
if isScheduled {
    let until = Date(timeIntervalSince1970: Double(localStartAt) / 1000.0)
        .addingTimeInterval(0.75)
    suppressUntil = max(suppressUntil, until)
}
```

**`PeerMesh`** exposes:

```swift
public func clockOffsetMs(forSender id: String) -> Int
```

Reads its existing per-peer `clockSync.estimatedOffsetMs()`. Returns 0 if the peer is unknown.

**`AppRuntime.init`** wires the closure when constructing the engine:

```swift
let engine = SyncEngine(
    senderId: id,
    broadcast: { ... },
    applyState: { _, _ in },
    clockOffsetMsFor: { [weak mesh] sid in
        mesh?.clockOffsetMs(forSender: sid) ?? 0
    }
)
```

Capture is `[weak mesh]` — mesh is already owned by `AppRuntime`, avoid a retain cycle.

**`SyncEngine.scheduleBufferMs`** default: `3000 → 800`.

**Host's own local apply** (`flushDebounce`, the `if scheduled` branch): unchanged. Host uses its own clock for `startAtMs` — no offset needed.

**JS (`InjectedJS.tunesyncApplyState`)**: unchanged. Still does `delay = startAtMs - Date.now()`. Receives a local-clock value now, so the math just works.

### Edge cases

- **Peer unknown / no ping samples yet** → offset = 0. Behavior matches today.
- **Stale offset** → `ClockSync` uses a rolling window of 5 samples; if the peer goes silent, the last estimate persists. Acceptable; will refresh on next ping.
- **Negative delay after correction** → `isScheduled = false`, forwards `nil`, JS plays immediately. Same fallback as today.
- **Suppression window** also keys on local clock, so the post-fire suppress works regardless of skew.

### Buffer change

`scheduleBufferMs = 800` is the new default. Sized for: one LAN hop (~10 ms) + JS evaluate + `setTimeout` arming (~50 ms) + headroom. Can be revisited if real-world LAN measurements demand a larger pad.

## Testing

1. **`testScheduledPlayHonorsClockOffset`** (new):
   - Inject `clockOffsetMsFor` returning `+2000` (peer 2 s ahead of local).
   - Send scheduled state with `startAtMs = nowMs + 500` → `localStartAt = nowMs - 1500` → not scheduled → `appliesScheduledAt[0] == nil`.
   - Send scheduled state with `startAtMs = nowMs + 2500` → `localStartAt = nowMs + 500` → scheduled → `appliesScheduledAt[0] == nowMs + 500`.

2. **Existing tests** unchanged: default offset closure returns 0, so `testRemoteScheduledPlayIsForwardedToApply`, `testScheduledPlaySuppressesRebroadcastUntilAfterFire`, etc. still pass.

3. **Manual verification**:
   - Two Macs, same room: countdown plays once on both, music starts together within ~50 ms.
   - Native ↔ browser at `http://localhost:8732/`: web client uses its own ping/pong offset; still aligned.

## Rollout

- Single commit on `fix/scheduled-play-loop` branch.
- Bump `0.4.4 → 0.4.5`.
- No data-format change to `StateMessage` — backwards compatible.

## Risks

- A peer that has never exchanged pings yields offset 0. Behavior is identical to today, so no regression risk.
- Buffer shrink to 800 ms exposes any peer whose `play()` arming + JS evaluate takes longer than ~750 ms. Unlikely on Apple Silicon Macs. Mitigation: bump back up if observed.
