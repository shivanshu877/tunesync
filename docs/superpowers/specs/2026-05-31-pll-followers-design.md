# PLL-follower sync (continuous rate-bend convergence)

**Status:** approved
**Date:** 2026-05-31
**Owner:** prateek

## Problem

The current schedule-then-play model couples three things that don't belong together:

1. The pre-pause hack on the host (kept music paused for 2 s while the wait window armed).
2. The defensive `play` event listener that fights YT Music's player layer.
3. A 2 000 ms click-to-audio delay just to absorb network jitter and clock skew.

Every transition (play, seek, track change) goes through this same heavy path, and the model produces visible artifacts (countdown overlay on plain play) and audible artifacts (pause-then-play stutter).

## Goal

Replace the wall-clock schedule with a **continuous follower** model. Host plays naturally; every peer measures the host's current position via clock-corrected wall-clock heartbeats and applies tiny `playbackRate` nudges to converge. Coverage is total — play, pause, seek, track change — through one mechanism.

Drift target: **<50 ms steady state**, **<2 s convergence** after any transition. Audibly synced in the same room.

## Non-goals

- Direct audio streaming (RTP/PCM). Out of scope.
- Lower drift than 50 ms. Out of scope.
- Replacing `ClockSync`. Already adequate; reuse as-is.

## Design

### Model

For every state broadcast the host emits:

```
{ videoId, t, playing, clientMs, [startAtMs] }
```

- `clientMs` — host's wall-clock when the message was encoded.
- `startAtMs` — present only on **track-change** messages (300 ms head-start so both peers can `loadVideoById` before pressing play). Plain play / pause / seek never carry it.

The peer computes the host's *current* position in local wall-clock:

```
hostNow      = myNow - clockOffsetMs(hostSenderId)
target_t     = msg.t + (hostNow - msg.clientMs) / 1000
diff         = target_t - currentTime
```

Then:

| `|diff|`       | action                                    |
|----------------|-------------------------------------------|
| > 2.0 s        | hard seek to `target_t`, then `play()`    |
| 100 ms – 2.0 s | rate-bend (PI controller, clamped ±0.5 %) |
| < 100 ms       | `playbackRate = 1.0` (locked)             |

Pause messages: `playing = false` → `v.pause()` immediately. No schedule.

Track-change messages: `videoId ≠ current` → navigate to the new URL with `&t=floor(target_t)`. After the new page injects the script, normal PLL takes over.

### PI controller

Simple form, no integral state needed for our convergence target:

```
rate = 1.0 + clamp(Kp * diff_seconds, -0.005, +0.005)
```

`Kp = 0.05` per second of error → 200 ms diff yields rate 1.01 → converges 200 ms in ~20 s. Too slow. Tighten:

`Kp = 0.25` → 200 ms diff yields rate 1.0125 → clamped to 1.005 → converges 200 ms in ~40 s.

The clamp is the binding constraint at the convergence target. Acceptable: rate-bend is for steady-state nudge; anything ≥ 100 ms is already at the clamp ceiling and converges at 0.5 %/s = ~200 ms per 40 s. Beyond 2 s the hard seek takes over.

If audible jitter remains, drop the rate clamp to ±0.25 % (still converges 200 ms in 80 s; hard seek catches anything bigger) or widen the hard-seek threshold to 1 s.

### Components & interfaces

**`SyncEngine.flushDebounce`** — strip out the `scheduled = s.playing && !lastBroadcastPlaying` gating, the `applyStateImpl(s, startAtMs)` local self-apply, and the `suppressUntil = startAt + 750ms` extension. The whole "pre-pause locally" path goes away. flushDebounce now just broadcasts `(t, playing, clientMs)` and notes it in history.

**`SyncEngine.apply`** — drop the `localStartAt` schedule arithmetic for plain state. Keep `startAtMs` forwarding for the track-change branch only. Strip the post-fire suppression window (no schedule = no fire to wait past).

**`SyncEngine`** — no longer needs `lastBroadcastPlaying` (rate-bend handles steady-state echo naturally; receiver only acts on host's heartbeats, not its own). Remove it.

**`InjectedJS.tunesyncApplyState`** — rewrite the playing branch. Compute `target_t`, decide hard-seek vs rate-bend vs locked, set `v.playbackRate`, call `v.play()`. Delete `pendingPlayTimeout`, `installScheduleHold`, `releaseScheduleHold`, `cancelPending`. The whole pre-pause apparatus is gone.

**`InjectedJS`** — wire `clientMs` and the sender's offset into the message. Today's message already carries `clientMs`; surface it to `tunesyncApplyState` as the third position arg or as part of an opts object.

**`PlayerController.applyState`** — adjust the JS invocation signature to pass `clientMs` and `senderOffsetMs` along.

**`BridgeAssets/app.js`** — mirror the native PLL. Use `clockOffsetMs` from its own ping/pong. Same `target_t` math, same thresholds, same rate clamps. Drop `applyAtMs` / `startAtMs` scheduling.

**`CountdownOverlay.swift`** — keep. `rt.scheduledAtMs` is now only set on track-change messages, so the overlay shows only during the 300 ms load window. Tweak the copy to "Loading on every Mac…" if visible.

**`AppRuntime`** — no signature changes.

### Edge cases

- **Host not yet known to receiver (no ping samples).** `clockOffsetMsFor` returns 0. Drift is bounded by network latency (~50 ms LAN). PLL converges as samples accumulate.
- **Track-change `startAtMs` already in the past for one peer.** That peer hard-seeks + plays immediately; PLL catches up.
- **YT Music inserts an ad on the host.** Host's `adShowing` flag already suppresses outbound state — receivers stay on their last `target_t` and free-run until ad ends. Existing behavior, no change.
- **Big seek (user scrubs).** Diff > 2 s → hard seek on every peer.
- **Pause race** — host pauses while a rate-bend is in flight. `playing = false` overrides rate; we set `v.pause()` and leave `playbackRate` at whatever it was. Next play resumes; rate-bend re-engages.

## Testing

Unit:

- `testPlainPlayBroadcastsNoStartAtMs` — `s.playing = true` with no videoId change → broadcast has `startAtMs == nil`.
- `testTrackChangeBroadcastsStartAtMs` — broadcast carrying a new `videoId` includes `startAtMs == nowMs + 300`.
- `testPauseBroadcastImmediate` — pause broadcast emitted with `startAtMs == nil` and no suppression window extension.
- `testRemotePlainStateForwardsClientMsForPLL` — `apply` forwards `clientMs` to `applyStateImpl` so the JS layer can do the math.

Manual:

- Two Macs in same room — start song on host, peer audibly catches up within ~2 s, holds <50 ms drift thereafter.
- Mid-song seek on host — both peers hard-seek and resume locked.
- Track change — both peers load and start together (300 ms window).
- Ad on host — host mutes, peer holds last position, both resume on ad end.

## Rollout

- One feature branch, one PR, one tag bump → Release Action.
- No backwards-compat field changes — `startAtMs` is now optional per message rather than always-present-on-play. Existing receivers (any unupgraded peer) treat a play without `startAtMs` as immediate apply with latency comp; that matches PLL's first iteration close enough that mixed-version rooms still mostly work.
- Bump to **0.5.0** (model change, not a fix).

## Risks

- **Rate-bend at 0.5 % audible** on some YT Music tracks (pitch shift ~9 cents). If reported, widen deadband to ±200 ms or shrink clamp to ±0.25 %.
- **YT Music ignores `playbackRate`** on some tracks (Music sometimes locks it). Fallback: when set fails, fall back to micro-seeks (`currentTime += diff_seconds` every 500 ms). Detect by reading back `playbackRate` after set.
- **Clock-offset estimate noisy** on first few pings → first 1–2 s after pairing have larger drift. Acceptable.
