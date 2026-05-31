# Wall-clock Scheduled Play (Clock-Offset Aware) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make scheduled play a pure wall-clock event that every peer fires at the same instant, by correcting the host-supplied `startAtMs` with the receiver's per-peer NTP-style clock offset, and shrinking the schedule buffer from 3000 ms → 800 ms.

**Architecture:** `SyncEngine.init` gains a `clockOffsetMsFor: (String) -> Int` closure (default `{ _ in 0 }`). On `apply`, the engine converts the host's `startAtMs` into the receiver's local clock frame using the offset for that sender, then uses the local value for `isScheduled` checks, for what it forwards to `applyStateImpl`, and for the post-fire suppression window. `AppRuntime` wires the closure to `PeerMesh.peerOffsetMs(senderId:)` (already implemented). Host's own local apply (`flushDebounce`) is unchanged — host uses its own clock as canonical.

**Tech Stack:** Swift 5.9 / Swift Package Manager / XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-31-wall-clock-schedule-design.md`

---

## File Structure

- Modify: `Sources/TuneSyncCore/SyncEngine.swift`
  - Add `clockOffsetMsFor` stored property and init param.
  - Use it in `apply` (receive branch) to compute `localStartAt` and the suppression window.
  - Drop `scheduleBufferMs` default `3000 → 800`.
- Modify: `Sources/TuneSync/ContentView.swift`
  - Wire `clockOffsetMsFor` closure to `mesh.peerOffsetMs(senderId:)` when constructing `SyncEngine`.
- Modify: `Tests/TuneSyncCoreTests/SyncEngineTests.swift`
  - Allow tests to inject a `clockOffsetMsFor` closure through `makeEngine`.
  - Add `testScheduledPlayHonorsClockOffset`.
- Modify: `Makefile`
  - Bump `0.4.4 → 0.4.5`.

`Sources/TuneSyncCore/PeerMesh.swift` already exposes `public func peerOffsetMs(senderId id: String) -> Int?` (PeerMesh.swift:184). No new accessor needed.

---

### Task 1: Plumb `clockOffsetMsFor` through `SyncEngine`

**Files:**
- Modify: `Sources/TuneSyncCore/SyncEngine.swift`
- Modify: `Tests/TuneSyncCoreTests/SyncEngineTests.swift`

- [ ] **Step 1: Update `makeEngine` test helper to accept an injectable offset closure**

Edit `Tests/TuneSyncCoreTests/SyncEngineTests.swift` — replace the existing `makeEngine` (around line 12) with:

```swift
    private func makeEngine(
        senderId: String = "self",
        recorder: Recorder,
        clockOffsetMsFor: @escaping (String) -> Int = { _ in 0 }
    ) -> SyncEngine {
        return SyncEngine(
            senderId: senderId,
            broadcast: { recorder.broadcasts.append($0) },
            applyState: { state, startAtMs in
                recorder.applies.append(state)
                recorder.appliesScheduledAt.append(startAtMs)
            },
            clockOffsetMsFor: clockOffsetMsFor
        )
    }
```

- [ ] **Step 2: Run tests to confirm they fail to compile**

Run: `swift test --filter SyncEngineTests 2>&1 | tail -20`

Expected: build error — `SyncEngine.init` has no `clockOffsetMsFor` parameter.

- [ ] **Step 3: Add the stored property and init param on `SyncEngine`**

Edit `Sources/TuneSyncCore/SyncEngine.swift`. Add a stored property near the other private state (after the `lastBroadcastPlaying` declaration, around line 103):

```swift
    /// Maps a sender's id to the NTP-style estimate of (their clock − our clock) in ms.
    /// Subtract from a remote `startAtMs` to convert it into our local clock frame.
    /// Defaults to 0 so single-peer / no-ping cases behave as if clocks were synced.
    private let clockOffsetMsFor: (String) -> Int
```

Then update the `init` signature (around line 105) — add the param at the end:

```swift
    public init(
        senderId: String,
        broadcast: @escaping (SyncMessage) -> Void,
        applyState: @escaping (PlayerState, Int64?) -> Void,
        debounceMs: Int = 200,
        suppressionMs: Int = 1500,
        heartbeatSeconds: Int = 1,
        applyOverheadMs: Int = 250,
        compCapMs: Int = 1500,
        scheduleBufferMs: Int = 800,
        clockOffsetMsFor: @escaping (String) -> Int = { _ in 0 }
    ) {
        self.senderId = senderId
        self.broadcast = broadcast
        self.applyStateImpl = applyState
        self.debounceMs = debounceMs
        self.suppressionMs = suppressionMs
        self.heartbeatSeconds = heartbeatSeconds
        self.applyOverheadMs = applyOverheadMs
        self.compCapMs = compCapMs
        self.scheduleBufferMs = scheduleBufferMs
        self.clockOffsetMsFor = clockOffsetMsFor
    }
```

(Two changes inline: `scheduleBufferMs` default flipped `3000 → 800`, and the new closure stored.)

- [ ] **Step 4: Run tests to verify compile + existing pass**

Run: `swift test --filter SyncEngineTests 2>&1 | tail -10`

Expected: all 25 existing tests pass. (No semantic change yet — closure is stored but unused; default offset is 0.)

- [ ] **Step 5: Commit**

```bash
git add Sources/TuneSyncCore/SyncEngine.swift Tests/TuneSyncCoreTests/SyncEngineTests.swift
git commit -m "refactor(sync): plumb clockOffsetMsFor closure through SyncEngine init"
```

---

### Task 2: Use the offset to convert `startAtMs` into the local clock frame

**Files:**
- Modify: `Sources/TuneSyncCore/SyncEngine.swift:178-219`

- [ ] **Step 1: Write the failing test**

Add to `Tests/TuneSyncCoreTests/SyncEngineTests.swift` right after `testScheduledPlaySuppressesRebroadcastUntilAfterFire`:

```swift
    func testScheduledPlayHonorsClockOffset() {
        // Peer's clock is 2000 ms ahead of ours. Their `startAtMs = nowMs + 500`
        // translates to localStartAt = nowMs - 1500 (already in our past) → must
        // NOT be treated as scheduled.
        let r = Recorder()
        let e = makeEngine(recorder: r, clockOffsetMsFor: { _ in 2000 })
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 9_000_000_000_000,
            videoId: "v", t: 10.0, playing: true,
            clientMs: nowMs,
            startAtMs: nowMs + 500
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertNil(r.appliesScheduledAt[0],
            "peer 2s ahead means their +500ms schedule lies in our past — apply now, not scheduled")

        // Same peer, but `startAtMs = nowMs + 2500` → localStartAt = nowMs + 500 → scheduled.
        let r2 = Recorder()
        let e2 = makeEngine(recorder: r2, clockOffsetMsFor: { _ in 2000 })
        let now2 = Int64(Date().timeIntervalSince1970 * 1000)
        e2.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 9_000_000_000_000,
            videoId: "v", t: 10.0, playing: true,
            clientMs: now2,
            startAtMs: now2 + 2500
        )))
        XCTAssertEqual(r2.applies.count, 1)
        XCTAssertNotNil(r2.appliesScheduledAt[0])
        // Forwarded value is in OUR clock frame, not the host's.
        let forwarded = r2.appliesScheduledAt[0]!
        XCTAssertEqual(forwarded, now2 + 2500 - 2000, accuracy: 50,
            "forwarded startAtMs must be host's startAtMs minus the offset")
    }
```

Note on `XCTAssertEqual(_:_:accuracy:)` for `Int64`: Swift's `XCTAssertEqual` has an `accuracy:` overload only for `FloatingPoint`. Use this alternative that works for `Int64`:

```swift
        XCTAssertTrue(abs(forwarded - (now2 + 2500 - 2000)) <= 50,
            "forwarded startAtMs must be host's startAtMs minus the offset (got \(forwarded))")
```

Replace the `XCTAssertEqual(forwarded, ...)` line in the test above with the `XCTAssertTrue` form.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testScheduledPlayHonorsClockOffset 2>&1 | tail -15`

Expected: FAIL — first assertion fails (`appliesScheduledAt[0]` is non-nil because the engine still ignores the offset and treats `nowMs + 500` as scheduled).

- [ ] **Step 3: Apply the offset in `apply`**

Edit `Sources/TuneSyncCore/SyncEngine.swift`. Replace the block currently at lines 178–195 (the part starting `lastApplied = key` through `let isScheduled = (s.startAtMs ?? 0) > nowMs` and the suppression-window assignment, including the comment about scheduled latency comp):

```swift
            lastApplied = key

            // Convert the host's wall-clock `startAtMs` into our local clock
            // frame using the per-peer NTP-style offset. Subtract because
            // `clockOffsetMsFor` returns (their_clock − our_clock) ms.
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let offsetMs = Int64(clockOffsetMsFor(s.senderId))
            let localStartAt: Int64 = (s.startAtMs ?? 0) - offsetMs
            let isScheduled = localStartAt > nowMs

            // Suppress local rebroadcasts until *after* the scheduled play
            // actually fires. Without this, the play event triggered by the
            // scheduled timer re-enters flushDebounce and schedules another
            // countdown — overlay re-appears in a loop.
            if isScheduled {
                let until = Date(timeIntervalSince1970: Double(localStartAt) / 1000.0)
                    .addingTimeInterval(0.75)
                suppressUntil = max(suppressUntil, until)
            } else {
                suppressUntil = Date().addingTimeInterval(Double(suppressionMs) / 1000.0)
            }
```

Then update the `applyStateImpl` call (currently around line 215) to forward `localStartAt`, not the raw `s.startAtMs`:

```swift
            applyStateImpl(
                PlayerState(videoId: s.videoId, t: effectiveT, playing: s.playing),
                isScheduled ? localStartAt : nil
            )
```

And update the `compNote` for the scheduled branch (currently around line 211) to log the offset-corrected value:

```swift
            } else if isScheduled {
                let inMs = localStartAt - nowMs
                compNote = "scheduled +\(inMs)ms (offset \(offsetMs)ms)"
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter testScheduledPlayHonorsClockOffset 2>&1 | tail -10`

Expected: PASS.

- [ ] **Step 5: Run full SyncEngine suite to confirm no regression**

Run: `swift test --filter SyncEngineTests 2>&1 | tail -10`

Expected: all 26 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TuneSyncCore/SyncEngine.swift Tests/TuneSyncCoreTests/SyncEngineTests.swift
git commit -m "fix(sync): convert remote startAtMs to local clock via per-peer offset"
```

---

### Task 3: Wire the closure to `PeerMesh.peerOffsetMs` in `AppRuntime`

**Files:**
- Modify: `Sources/TuneSync/ContentView.swift:52-64`

- [ ] **Step 1: Update the `SyncEngine` construction in `AppRuntime.init`**

Edit `Sources/TuneSync/ContentView.swift`. Replace the `SyncEngine(...)` construction in `AppRuntime.init` (currently lines 54–61) with:

```swift
        let mesh = PeerMesh(senderId: id, displayName: name, room: "default")
        let webBridgeBox = self.webBridgeBox
        let engine = SyncEngine(
            senderId: id,
            broadcast: { [weak mesh] msg in
                mesh?.broadcast(msg)
                webBridgeBox.bridge?.broadcastToClients(msg)
            },
            applyState: { _, _ in },
            clockOffsetMsFor: { [weak mesh] sid in
                mesh?.peerOffsetMs(senderId: sid) ?? 0
            }
        )
```

(The closure is `[weak mesh]` to avoid a retain cycle — `mesh` is owned by `AppRuntime` via `self.mesh` below.)

- [ ] **Step 2: Build the app target to verify it compiles**

Run: `swift build -c release 2>&1 | tail -5`

Expected: `Build complete!` (warnings about unrelated SendableClosureCaptures in PeerMesh are pre-existing — ignore).

- [ ] **Step 3: Run all tests**

Run: `swift test 2>&1 | tail -10`

Expected: all 56 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/TuneSync/ContentView.swift
git commit -m "feat(sync): wire SyncEngine clock offset to PeerMesh per-peer estimate"
```

---

### Task 4: Bump version and rebuild bundle

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Bump the version string in three places**

Run:

```bash
sed -i '' 's/0.4.4/0.4.5/g' Makefile
grep "0.4" Makefile
```

Expected output:

```
DMG        = TuneSync-0.4.5.dmg
'<key>CFBundleVersion</key><string>0.4.5</string>' \
'<key>CFBundleShortVersionString</key><string>0.4.5</string>' \
```

- [ ] **Step 2: Rebuild bundle**

Run: `make bundle 2>&1 | tail -3`

Expected:

```
cp .build/release/TuneSync TuneSync.app/Contents/MacOS/TuneSync
Built TuneSync.app
```

- [ ] **Step 3: Run the bundled app from the working directory (not /Applications)**

Run:

```bash
pkill -f "personal/tunesync/TuneSync.app/Contents/MacOS" 2>/dev/null; sleep 1
/Users/prateekbhardwaj/Developer/personal/tunesync/TuneSync.app/Contents/MacOS/TuneSync > /tmp/ts.log 2>&1 &
sleep 2
lsof -nP -iTCP:8732 -sTCP:LISTEN 2>/dev/null | tail -1
```

Expected: a `TuneSync` line listening on port 8732 (the web bridge — confirms the binary launched).

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: bump to 0.4.5"
```

---

### Task 5: Push branch and update the PR

**Files:** none (git/gh commands only).

- [ ] **Step 1: Push the branch**

Run: `git push 2>&1 | tail -5`

Expected: pushes new commits to `origin/fix/scheduled-play-loop`.

- [ ] **Step 2: Update PR body**

Run:

```bash
gh pr edit 4 --title "fix(sync): clock-offset-aware wall-clock scheduled play (v0.4.5)" --body "$(cat <<'EOF'
## Summary
Scheduled play is now a pure wall-clock event corrected for per-peer clock skew. The host's `startAtMs` is converted into the receiver's local clock frame via the NTP-style estimate that `ClockSync` already produces (and that `PeerMesh.peerOffsetMs(senderId:)` already exposes). Buffer shortened `3000 ms → 800 ms` now that skew is corrected.

## Why this fixes "host waits, peers play immediately"
Before: `isScheduled = s.startAtMs > Date()` compared a host wall-clock value to the receiver's wall-clock with no correction. Any skew >3 s flipped `isScheduled` to false on the receiver, which then forwarded `nil` to JS and played immediately while the host correctly waited 3 s.

After: `localStartAt = s.startAtMs − offsetMs(senderId)` lands the schedule in the receiver's own clock frame. Same instant, every peer.

## Changes
- `SyncEngine.init` takes a `clockOffsetMsFor: (String) -> Int` closure (default `{ _ in 0 }`).
- `SyncEngine.apply` computes `localStartAt` and uses it for the scheduled check, the forwarded `startAtMs`, and the post-fire suppression window.
- `AppRuntime` wires the closure to `mesh.peerOffsetMs(senderId:)`.
- `scheduleBufferMs` default `3000 → 800`.
- New unit test: `testScheduledPlayHonorsClockOffset`.

## Test plan
- [x] Full test suite — 56/56 pass
- [x] App rebuilds + runs from `./TuneSync.app`
- [ ] Manual: two Macs in same room — countdown plays once on both, music starts together within ~50 ms
- [ ] Manual: host ↔ browser at \`http://localhost:8732/\` — web client still aligned (its own ping/pong unchanged)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected output: a URL ending in `/pull/4`.

---

## Self-review notes

- **Spec coverage:** §Data flow (Task 2), §Components & interfaces (Tasks 1–3), §Buffer change (Task 1, Step 3 default flip), §Testing (Task 2 Step 1), §Rollout (Tasks 4–5).
- **Placeholder scan:** no TBDs; all code blocks are concrete.
- **Type consistency:** closure signature `(String) -> Int` is used identically in `SyncEngine.init`, `makeEngine`, and the `AppRuntime` wiring. `peerOffsetMs(senderId:) -> Int?` returns optional; both callers (`AppRuntime` and the unit test) coalesce with `?? 0` / inline literal.
- **Edge case (peer not yet pinged):** `mesh.peerOffsetMs` returns `nil` → wired closure returns 0 → behavior matches today. Covered by the existing tests that pass the default closure.
