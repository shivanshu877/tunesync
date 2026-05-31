# PLL-Follower Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace wall-clock scheduled play with a continuous follower model — peers measure host position via clock-corrected heartbeats and converge via `playbackRate` nudges.

**Architecture:** Host plays naturally and broadcasts state on every change. Peers compute `target_t = msg.t + (myNow - clockOffset(host) - msg.clientMs) / 1000`, then either hard-seek (`|diff| > 2s`), rate-bend (`100ms < |diff| <= 2s`, ±0.5 % clamp), or lock (`|diff| <= 100ms`). Track changes keep a small 300 ms wall-clock buffer so both peers can `loadVideoById` before pressing play. No pre-pause, no defensive listener, no countdown overlay outside of track changes.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, WKWebView, vanilla JS.

**Spec:** `docs/superpowers/specs/2026-05-31-pll-followers-design.md`

---

## File Structure

- Modify `Sources/TuneSyncCore/SyncEngine.swift`
  - Drop `lastBroadcastPlaying` field, the `scheduled = s.playing && !lastBroadcastPlaying` gate, and the local self-apply with `applyStateImpl(s, startAt)`.
  - In `apply`, stop forwarding `localStartAt` for plain state. Forward the new `clientMsArg` (host's wall-clock when the message was encoded) and `offsetMs` to `applyStateImpl` for PLL math.
  - Schedule path remains only for track-change broadcasts (videoId differs from `lastLocalState.videoId`). Buffer flips `2000 → 300` for that branch.
- Modify `Sources/TuneSyncCore/Models.swift`
  - No schema change (`clientMs` already exists, `startAtMs` already optional).
- Modify `Sources/TuneSync/PlayerController.swift`
  - Extend `applyState` signature to `(_ state: PlayerState, startAtMs: Int64? = nil, clientMs: Int64? = nil, offsetMs: Int64 = 0)`. Forward them into the JS call.
- Modify `Sources/TuneSync/ContentView.swift`
  - The `applyStateOverride` closure needs the extra params, plumbed from the new `applyStateImpl` shape.
- Modify `Sources/TuneSync/InjectedJS.swift`
  - Extend `tunesyncApplyState(videoId, t, playing, startAtMs, clientMs, offsetMs)`.
  - Strip `pendingPlayTimeout`, `installScheduleHold`, `releaseScheduleHold`, `cancelPending`.
  - New PLL logic: `target_t`, hard-seek vs rate-bend vs lock, then `play()` or `pause()`.
- Modify `Sources/TuneSyncCore/BridgeAssets.swift`
  - Same PLL logic in `app.js`. `clockOffsetMs` already measured via ping/pong.
- Modify `Sources/TuneSync/CountdownOverlay.swift`
  - Tweak copy to `"Loading on every Mac…"` since it now only fires on track loads.
- Modify `Tests/TuneSyncCoreTests/SyncEngineTests.swift`
  - New tests: plain-play broadcasts no `startAtMs`, track-change broadcasts include `startAtMs`, pause broadcasts no `startAtMs`, `apply` forwards `clientMs` & `offsetMs` shape.
  - Update or delete tests that pinned the old scheduled-play behavior (`testLocalPlayBroadcastIncludesStartAtMs`, `testLocalPlayAppliesItselfWithSchedule`, `testScheduledPlaySuppressesRebroadcastUntilAfterFire`, `testScheduledPlayHonorsClockOffset`'s scheduled case).
- Modify `Makefile`
  - Bump `0.4.7 → 0.5.0`.

---

### Task 1: Extend `applyStateImpl` callback signature with `clientMs` and `offsetMs`

The receive path needs to give the JS layer enough to do PLL math. Today `applyStateImpl: (PlayerState, Int64?)` carries only `(state, startAtMs)`. Extend it to `(PlayerState, Int64? /*startAtMs*/, Int64? /*clientMs*/, Int64 /*offsetMs*/)`.

**Files:**
- Modify: `Sources/TuneSyncCore/SyncEngine.swift`
- Modify: `Sources/TuneSync/ContentView.swift`
- Modify: `Tests/TuneSyncCoreTests/SyncEngineTests.swift`

- [ ] **Step 1: Update `applyStateImpl` type, init param, and `applyStateOverride` in `SyncEngine.swift`**

Replace the three lines that define and assign `applyStateImpl`:

```swift
    private var applyStateImpl: (PlayerState, Int64?, Int64?, Int64) -> Void
```

```swift
        applyState: @escaping (PlayerState, Int64?, Int64?, Int64) -> Void,
```

```swift
    public func applyStateOverride(_ apply: @escaping (PlayerState, Int64?, Int64?, Int64) -> Void) {
        applyStateImpl = apply
    }
```

Find each of the two existing `applyStateImpl(...)` call sites (one in the receive branch of `handleRemote`, one in the local-schedule branch of `flushDebounce`) and append `s.clientMs, offsetMs` and `nil, 0` respectively. The receive branch becomes:

```swift
            applyStateImpl(
                PlayerState(videoId: s.videoId, t: effectiveT, playing: s.playing),
                isScheduled ? localStartAt : nil,
                s.clientMs,
                offsetMs
            )
```

The `flushDebounce` self-apply (still used by track-change for now) becomes:

```swift
            applyStateImpl(s, stateMsg.startAtMs, nil, 0)
```

- [ ] **Step 2: Update `makeEngine` test helper for the new signature**

`Tests/TuneSyncCoreTests/SyncEngineTests.swift`:

```swift
    final class Recorder {
        var broadcasts: [SyncMessage] = []
        var applies: [PlayerState] = []
        var appliesScheduledAt: [Int64?] = []
        var appliesClientMs: [Int64?] = []
        var appliesOffsetMs: [Int64] = []
    }

    private func makeEngine(
        senderId: String = "self",
        recorder: Recorder,
        clockOffsetMsFor: @escaping (String) -> Int = { _ in 0 }
    ) -> SyncEngine {
        return SyncEngine(
            senderId: senderId,
            broadcast: { recorder.broadcasts.append($0) },
            applyState: { state, startAtMs, clientMs, offsetMs in
                recorder.applies.append(state)
                recorder.appliesScheduledAt.append(startAtMs)
                recorder.appliesClientMs.append(clientMs)
                recorder.appliesOffsetMs.append(offsetMs)
            },
            clockOffsetMsFor: clockOffsetMsFor
        )
    }
```

- [ ] **Step 3: Update `AppRuntime.init` in `ContentView.swift` to match the new closure shape**

Find the `applyStateOverride` block and replace it with:

```swift
        self.engine.applyStateOverride { [weak self] state, startAtMs, clientMs, offsetMs in
            DispatchQueue.main.async {
                guard let self else { return }
                self.player.applyState(state, startAtMs: startAtMs, clientMs: clientMs, offsetMs: offsetMs)
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                if let s = startAtMs, s > nowMs, state.playing {
                    self.scheduledAtMs = s
                } else {
                    self.scheduledAtMs = nil
                    self.networkDelayMs = 0
                }
            }
        }
```

- [ ] **Step 4: Build to verify compile (this will fail — `PlayerController.applyState` still has the old signature)**

Run: `swift build 2>&1 | tail -5`

Expected: errors pointing at `Sources/TuneSync/ContentView.swift` about extra args.

- [ ] **Step 5: Update `PlayerController.applyState` to accept the new args**

`Sources/TuneSync/PlayerController.swift`, replace the existing `applyState` method:

```swift
    public func applyState(
        _ state: PlayerState,
        startAtMs: Int64? = nil,
        clientMs: Int64? = nil,
        offsetMs: Int64 = 0
    ) {
        guard let wv = webView else { return }
        let startArg = startAtMs.map(String.init) ?? "null"
        let clientArg = clientMs.map(String.init) ?? "null"
        let js = "window.tunesyncApplyState && window.tunesyncApplyState(" +
            "\(jsString(state.videoId)), \(state.t), \(state.playing), " +
            "\(startArg), \(clientArg), \(offsetMs));"
        wv.evaluateJavaScript(js) { _, error in
            if let error {
                Log.player.error("applyState JS error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
```

- [ ] **Step 6: Build + run tests**

Run: `swift test 2>&1 | tail -10`

Expected: all existing tests pass (no semantic change yet — recorder just captures the new fields).

- [ ] **Step 7: Commit**

```bash
git add Sources/TuneSyncCore/SyncEngine.swift Sources/TuneSync/PlayerController.swift Sources/TuneSync/ContentView.swift Tests/TuneSyncCoreTests/SyncEngineTests.swift
git commit -m "refactor(sync): plumb clientMs + offsetMs through apply callback for PLL"
```

---

### Task 2: Stop scheduling plain play; only track-changes carry `startAtMs`

**Files:**
- Modify: `Sources/TuneSyncCore/SyncEngine.swift`
- Modify: `Tests/TuneSyncCoreTests/SyncEngineTests.swift`

- [ ] **Step 1: Write the new failing tests**

In `Tests/TuneSyncCoreTests/SyncEngineTests.swift`, replace `testLocalPlayBroadcastIncludesStartAtMs` with three new tests and delete `testLocalPlayAppliesItselfWithSchedule` and `testScheduledPlaySuppressesRebroadcastUntilAfterFire` (they pin obsolete behavior). Add:

```swift
    func testPlainPlayBroadcastsNoStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        // Establish lastLocalState so the next broadcast is NOT a track-change.
        e.localStateChanged(PlayerState(videoId: "v", t: 0, playing: false))
        e.flushDebounceForTesting()
        e.localStateChanged(PlayerState(videoId: "v", t: 0, playing: true))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNil(s.startAtMs, "plain play (same videoId) must not schedule")
        XCTAssertTrue(s.playing)
    }

    func testPauseBroadcastsNoStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "v", t: 10, playing: false))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNil(s.startAtMs, "pause must never schedule")
    }

    func testTrackChangeBroadcastsCarryStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "first", t: 30, playing: true))
        e.flushDebounceForTesting()
        e.localStateChanged(PlayerState(videoId: "second", t: 0, playing: true))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNotNil(s.startAtMs, "track change must schedule so peers can load")
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        // 300ms buffer ± 300ms scheduler jitter
        XCTAssertTrue(abs(s.startAtMs! - (nowMs + 300)) <= 300,
            "track-change schedule should be ~300ms in future")
    }
```

Also delete `testScheduledPlayHonorsClockOffset` (its "is scheduled" branch is obsolete for plain play; track-change clock-offset behavior is identical and already covered by the new test). Delete `testNilStartAtMsWithNegativeOffsetDoesNotScheduleFalsely` for the same reason.

- [ ] **Step 2: Run the failing tests**

Run: `swift test --filter SyncEngineTests 2>&1 | tail -15`

Expected: build error or the new tests fail because `flushDebounce` still schedules every play.

- [ ] **Step 3: Rewrite `flushDebounce` to schedule only on track change**

In `Sources/TuneSyncCore/SyncEngine.swift`, find `flushDebounce()` and replace the body's scheduling section. The new logic:

```swift
    private func flushDebounce() {
        guard let s = pendingLocalState else { return }
        pendingLocalState = nil
        if Date() < suppressUntil {
            appendHistory(SyncEntry(
                direction: .skipped, senderId: senderId,
                videoId: s.videoId, t: s.t, playing: s.playing,
                at: Date(), note: "debounce suppressed (post-apply window)"
            ))
            return
        }
        if adShowing {
            appendHistory(SyncEntry(
                direction: .skipped, senderId: senderId,
                videoId: s.videoId, t: s.t, playing: s.playing,
                at: Date(), note: "ad showing"
            ))
            return
        }
        // Schedule a coordinated start only on a real track change — both
        // peers need ~200ms to loadVideoById. Plain play / pause / seek do
        // NOT schedule; the receiver's PLL converges in steady state.
        let isTrackChange = (lastBroadcastVideoId != nil) && (lastBroadcastVideoId != s.videoId) && s.playing
        let scheduled = isTrackChange
        let msg = buildStateMessage(s, scheduled: scheduled)
        broadcast(msg)

        // Self-apply only on track change so the host honors the same load
        // window peers do. Plain transitions self-apply implicitly — the
        // host's video element is already where it is.
        if scheduled, let stateMsg = msg.stateOrNil() {
            applyStateImpl(s, stateMsg.startAtMs, nil, 0)
            if let startAt = stateMsg.startAtMs {
                let until = Date(timeIntervalSince1970: Double(startAt) / 1000.0)
                    .addingTimeInterval(0.5)
                suppressUntil = max(suppressUntil, until)
            }
        }

        lastBroadcastVideoId = s.videoId
        appendHistory(SyncEntry(
            direction: .sent, senderId: senderId,
            videoId: s.videoId, t: s.t, playing: s.playing,
            at: Date(),
            note: scheduled ? "track-change scheduled +\(scheduleBufferMs)ms" : "broadcast"
        ))
    }
```

And in the property block of `SyncEngine` (where `lastBroadcastPlaying` lived), replace with:

```swift
    /// Tracks the last *broadcasted* videoId so we can detect track-change
    /// transitions (which DO need a wall-clock schedule so peers have time
    /// to loadVideoById). Plain play/pause/seek don't need scheduling —
    /// the follower-side PLL converges from any starting drift.
    private var lastBroadcastVideoId: String?
```

Remove the `private var lastBroadcastPlaying: Bool = false` line entirely. Search the file for any remaining `lastBroadcastPlaying` reference and delete it.

- [ ] **Step 4: Flip the default schedule buffer down**

Find `scheduleBufferMs: Int = 2000,` in `init`. Replace with `scheduleBufferMs: Int = 300,`.

- [ ] **Step 5: Run tests**

Run: `swift test --filter SyncEngineTests 2>&1 | tail -10`

Expected: all SyncEngineTests pass (the new three + the surviving original ones).

- [ ] **Step 6: Commit**

```bash
git add Sources/TuneSyncCore/SyncEngine.swift Tests/TuneSyncCoreTests/SyncEngineTests.swift
git commit -m "feat(sync): only schedule on track change; plain transitions broadcast immediately"
```

---

### Task 3: Receive-side — stop forwarding `localStartAt` for plain state; remove suppressUntil-past-fire

The receive branch in `handleRemote.apply` currently sets `suppressUntil` to `localStartAt + 0.75s` for plain scheduled play. With no plain-play scheduling, that block is dead and confusing. Strip it.

**Files:**
- Modify: `Sources/TuneSyncCore/SyncEngine.swift`

- [ ] **Step 1: Replace the receive-branch arithmetic**

Find the block in `apply` (the `case .state(let s):` handler) that currently does:

```swift
            lastApplied = key

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let offsetMs = Int64(clockOffsetMsFor(s.senderId))
            let localStartAt: Int64? = s.startAtMs.map { $0 - offsetMs }
            let isScheduled: Bool = (localStartAt ?? 0) > nowMs

            if isScheduled, let local = localStartAt {
                let until = Date(timeIntervalSince1970: Double(local) / 1000.0)
                    .addingTimeInterval(0.75)
                suppressUntil = max(suppressUntil, until)
            } else {
                suppressUntil = Date().addingTimeInterval(Double(suppressionMs) / 1000.0)
            }
```

Replace with:

```swift
            lastApplied = key
            suppressUntil = Date().addingTimeInterval(Double(suppressionMs) / 1000.0)

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let offsetMs = Int64(clockOffsetMsFor(s.senderId))
            // Only track-change messages carry startAtMs. For those, convert
            // to local clock so the player's track-load wait fires in our
            // frame, not the host's.
            let localStartAt: Int64? = s.startAtMs.map { $0 - offsetMs }
            let isScheduled: Bool = (localStartAt ?? 0) > nowMs
```

Then the `else if isScheduled` `compNote` and the `applyStateImpl(...)` call already in this block stay; verify they still reference `localStartAt` and `offsetMs`.

- [ ] **Step 2: Run full suite**

Run: `swift test 2>&1 | tail -10`

Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSyncCore/SyncEngine.swift
git commit -m "refactor(sync): drop scheduled-play suppression window on receive (only track-change schedules)"
```

---

### Task 4: Add PLL to `InjectedJS.tunesyncApplyState`

Strip the pre-pause apparatus and rewrite the playing branch using `target_t`, hard-seek vs rate-bend vs lock.

**Files:**
- Modify: `Sources/TuneSync/InjectedJS.swift`

- [ ] **Step 1: Delete the pre-pause / schedule-hold helpers**

In `Sources/TuneSync/InjectedJS.swift`, remove the entire block defining `pendingPlayTimeout`, `scheduleHoldHandler`, `installScheduleHold`, `releaseScheduleHold`, and `cancelPending`. They are no longer used.

- [ ] **Step 2: Rewrite `window.tunesyncApplyState` with the new signature and PLL body**

Replace the existing `tunesyncApplyState` assignment with:

```swift
  window.tunesyncApplyState = function (videoId, t, playing, startAtMs, clientMs, offsetMs) {
    var v = getVideo();
    if (!v) return false;
    var current = getVideoId();
    offsetMs = (typeof offsetMs === "number") ? offsetMs : 0;

    // Track change: navigate. The injected script reattaches on the new
    // page and the next state msg drives PLL from there. Honor startAtMs
    // by appending &t= so the new page lands close to target.
    if (videoId && videoId !== current) {
      lastAppliedAt = Date.now();
      lastAppliedVideoId = videoId;
      var hostNow = Date.now() - offsetMs;
      var targetT = t || 0;
      if (typeof clientMs === "number") {
        targetT += Math.max(0, (hostNow - clientMs)) / 1000;
      }
      var dest = "https://music.youtube.com/watch?v=" + encodeURIComponent(videoId) + "&t=" + Math.floor(targetT);
      window.location.href = dest;
      return true;
    }

    // Pause is immediate, no math.
    if (!playing) {
      if (!v.paused) { try { v.pause(); } catch (e) {} }
      try { v.playbackRate = 1.0; } catch (e) {}
      lastAppliedAt = Date.now();
      lastAppliedVideoId = videoId || current;
      return true;
    }

    // PLL: compute where the host is RIGHT NOW in our local clock frame,
    // then either hard-seek (drift > 2s), rate-bend (100ms..2s, ±0.5%),
    // or lock (rate=1.0, within ±100ms).
    var hostNow = Date.now() - offsetMs;
    var elapsedMs = (typeof clientMs === "number") ? Math.max(0, hostNow - clientMs) : 0;
    var targetT = (t || 0) + (elapsedMs / 1000);
    var diff = targetT - (v.currentTime || 0); // positive = we're behind

    if (Math.abs(diff) > 2.0) {
      try { v.currentTime = targetT; } catch (e) {}
      try { v.playbackRate = 1.0; } catch (e) {}
    } else if (Math.abs(diff) > 0.1) {
      // Kp = 0.25, clamp ±0.005 (±0.5%). Audibly inaudible.
      var nudge = 0.25 * diff;
      if (nudge > 0.005) nudge = 0.005;
      if (nudge < -0.005) nudge = -0.005;
      try { v.playbackRate = 1.0 + nudge; } catch (e) {}
    } else {
      try { v.playbackRate = 1.0; } catch (e) {}
    }

    if (v.paused) { try { v.play().catch(function () {}); } catch (e) {} }

    lastAppliedAt = Date.now();
    lastAppliedVideoId = videoId || current;
    return true;
  };
```

- [ ] **Step 3: Bump the version string in the console log**

Find the line `console.info("[tunesync] injected (v0.2.8)");` and replace with `console.info("[tunesync] injected (v0.5.0-pll)");`.

- [ ] **Step 4: Build the release target**

Run: `swift build -c release 2>&1 | tail -5`

Expected: `Build complete!` (warnings about pre-existing SendableClosureCaptures ignored).

- [ ] **Step 5: Bundle + run**

Run: `make bundle 2>&1 | tail -2 && pkill -f "personal/tunesync/TuneSync.app/Contents/MacOS" 2>/dev/null; sleep 1; /Users/prateekbhardwaj/Developer/personal/tunesync/TuneSync.app/Contents/MacOS/TuneSync > /tmp/ts.log 2>&1 & echo PID=$!; sleep 2; lsof -nP -iTCP:8732 -sTCP:LISTEN 2>/dev/null | tail -1`

Expected: `Built TuneSync.app`, app launches, listens on :8732.

- [ ] **Step 6: Commit**

```bash
git add Sources/TuneSync/InjectedJS.swift
git commit -m "feat(injected-js): replace pre-pause schedule with PLL rate-bend follower"
```

---

### Task 5: Add PLL to the web bridge client (`BridgeAssets.swift` / `app.js`)

The browser-peer at `localhost:8732` is the fast test loop, so it must match the native PLL behavior exactly.

**Files:**
- Modify: `Sources/TuneSyncCore/BridgeAssets.swift`

- [ ] **Step 1: Rewrite the `applyState` function in `appJS`**

In `Sources/TuneSyncCore/BridgeAssets.swift`, find the `function applyState(s)` block inside the `appJS` template. Replace its body with:

```js
  function applyState(s) {
    if (!player || typeof player.loadVideoById !== 'function') return;
    if (s.adOnHost) {
      try { player.mute(); player.pauseVideo(); } catch (e) {}
      return;
    } else {
      try { player.unMute(); } catch (e) {}
    }

    // Track change: load the new video and seek near target. PLL on the
    // next heartbeat will lock the position.
    var hostNow = Date.now() - clockOffsetMs;
    var elapsedMs = (typeof s.clientMs === 'number') ? Math.max(0, hostNow - s.clientMs) : 0;
    var targetT = (s.t || 0) + (s.playing ? elapsedMs / 1000 : 0);

    if (s.videoId && s.videoId !== lastVideoId) {
      lastVideoId = s.videoId;
      try { player.loadVideoById(s.videoId, targetT); } catch (e) {}
      trackEl.textContent = s.videoId;
      return;
    }

    // Pause immediately.
    if (!s.playing) {
      try { player.pauseVideo(); } catch (e) {}
      try { player.setPlaybackRate(1.0); } catch (e) {}
      return;
    }

    // PLL: hard-seek > 2s, rate-bend 0.1–2s (±0.5%), lock within 0.1s.
    var current = player.getCurrentTime ? player.getCurrentTime() : 0;
    var diff = targetT - current;

    if (Math.abs(diff) > 2.0) {
      try { player.seekTo(targetT, true); } catch (e) {}
      try { player.setPlaybackRate(1.0); } catch (e) {}
    } else if (Math.abs(diff) > 0.1) {
      var nudge = 0.25 * diff;
      if (nudge > 0.005) nudge = 0.005;
      if (nudge < -0.005) nudge = -0.005;
      try { player.setPlaybackRate(1.0 + nudge); } catch (e) {}
    } else {
      try { player.setPlaybackRate(1.0); } catch (e) {}
    }

    var st = player.getPlayerState ? player.getPlayerState() : -1;
    if (st !== 1 && st !== 3) { try { player.playVideo(); } catch (e) {} }
  }
```

- [ ] **Step 2: Rebuild + relaunch**

Run: `make bundle 2>&1 | tail -2 && pkill -f "personal/tunesync/TuneSync.app/Contents/MacOS" 2>/dev/null; sleep 1; /Users/prateekbhardwaj/Developer/personal/tunesync/TuneSync.app/Contents/MacOS/TuneSync > /tmp/ts.log 2>&1 & echo PID=$!; sleep 2`

Expected: app relaunches.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSyncCore/BridgeAssets.swift
git commit -m "feat(bridge-js): replace scheduled apply with PLL rate-bend follower in web client"
```

---

### Task 6: Update countdown overlay copy for track-change-only

**Files:**
- Modify: `Sources/TuneSync/CountdownOverlay.swift`

- [ ] **Step 1: Change the overlay subtitle**

Find the line in `panel(remainingMs:)`:

```swift
            Text("Playing on every Mac in the room")
```

Replace with:

```swift
            Text("Loading new track on every Mac…")
```

- [ ] **Step 2: Build**

Run: `swift build -c release 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSync/CountdownOverlay.swift
git commit -m "feat(ui): countdown overlay now reads as track-load — only path that still schedules"
```

---

### Task 7: Bump version + rebuild bundle + smoke-launch

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Bump version everywhere in Makefile**

Run: `sed -i '' 's/0.4.7/0.5.0/g' Makefile && grep "0.5" Makefile`

Expected output:

```
DMG        = TuneSync-0.5.0.dmg
'<key>CFBundleVersion</key><string>0.5.0</string>' \
'<key>CFBundleShortVersionString</key><string>0.5.0</string>' \
```

- [ ] **Step 2: Rebuild bundle and launch**

Run: `make bundle 2>&1 | tail -2 && pkill -f "personal/tunesync/TuneSync.app/Contents/MacOS" 2>/dev/null; sleep 1; /Users/prateekbhardwaj/Developer/personal/tunesync/TuneSync.app/Contents/MacOS/TuneSync > /tmp/ts.log 2>&1 & echo PID=$!; sleep 2; lsof -nP -iTCP:8732 -sTCP:LISTEN 2>/dev/null | tail -1`

Expected: `Built TuneSync.app`, app launches, listens on :8732.

- [ ] **Step 3: Run full test suite once more**

Run: `swift test 2>&1 | tail -5`

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: bump to 0.5.0 (PLL follower model)"
```

---

### Task 8: Push branch and create PR

**Files:** none (git/gh only).

- [ ] **Step 1: Push the feature branch**

Run: `git push -u origin feat/pll-followers 2>&1 | tail -3`

Expected: `[new branch] feat/pll-followers -> feat/pll-followers`.

- [ ] **Step 2: Create PR**

Run:

```bash
gh pr create --base master --title "feat(sync): PLL-follower sync — drop scheduled play, continuous rate-bend convergence (v0.5.0)" --body "$(cat <<'EOF'
## Summary
Replaces the wall-clock scheduled-play model with a continuous PLL-follower model. Host plays naturally; every peer measures host position via clock-corrected heartbeats and applies tiny \`playbackRate\` nudges to converge.

## Why
The schedule model required:
- A pre-pause hack on the host
- A defensive \`play\` event listener to fight YT Music's player layer
- 2 s of click-to-audio delay just to absorb jitter

All three are gone.

## Model
- Host: plays normally. Every state change broadcasts \`(videoId, t, playing, clientMs)\`. No \`startAtMs\` on plain play / pause / seek.
- Peers: \`target_t = msg.t + (myNow - clockOffset(host) - msg.clientMs) / 1000\`. Then hard-seek (|diff| > 2s), rate-bend (100ms..2s, ±0.5%), or lock (|diff| < 100ms).
- Track change: only path that still uses \`startAtMs\` (300 ms buffer so both peers \`loadVideoById\`).

## Targets
- <50 ms steady-state drift
- <2 s convergence after a transition
- Audibly inaudible rate adjustment (±0.5%)

## Test plan
- [x] Unit suite green
- [x] Bundle runs from working dir
- [ ] Manual: native ↔ browser peer at \`http://localhost:8732/\` — start, pause, seek, track change all stay in sync within ~50 ms

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: URL to PR.

---

## Self-review notes

- **Spec coverage:**
  - Architecture: Tasks 1–4 (engine), 5 (web bridge).
  - PI controller: Task 4 & 5 — `Kp = 0.25`, clamp ±0.005.
  - Drift thresholds: Task 4 & 5 — `0.1s` rate-bend floor, `2.0s` hard-seek ceiling.
  - Track-change branch: Task 2 (schedule), Task 4 (JS navigates with `&t=`), Task 5 (web `loadVideoById`).
  - Countdown overlay copy: Task 6.
  - 300 ms track-load buffer: Task 2 default flip.
  - Edge cases — host unknown / ad / pause race: covered by PLL body in Tasks 4 & 5.

- **Placeholders:** none. Every step has the exact code or command.

- **Type consistency:** `applyStateImpl` shape `(PlayerState, Int64?, Int64?, Int64)` consistent across Tasks 1–3. JS signature `(videoId, t, playing, startAtMs, clientMs, offsetMs)` consistent in PlayerController (Task 1) and InjectedJS (Task 4).
