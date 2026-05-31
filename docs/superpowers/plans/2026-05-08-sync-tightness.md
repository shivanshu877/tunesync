# Sync Tightness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tighten cross-Mac playback alignment from "~1 s slop" to "≤150 ms steady-state, ≤300 ms on track-change". Fold in the skip-ad detector so an ad on the host pauses + mutes guests until the ad ends.

**Architecture:** New pure-logic `ClockSync` module estimates per-peer wallclock offset and RTT from existing ping/pong. `StateMessage` gains `applyAtMs` (sender's intended apply wallclock). Receivers translate via offset and schedule the apply via `setTimeout` in injected JS. Guests apply soft drift correction with `playbackRate` for sub-500 ms errors instead of hard seeks. Ad on host broadcasts `adOnHost=true`; guests pause + mute until cleared.

**Tech Stack:** Swift 6 (`TuneSyncCore`), JavaScript (injected), `XCTest`.

---

## File Structure

- `Sources/TuneSyncCore/ClockSync.swift` — new. Pure offset/RTT estimator. Sliding window of NTP-style samples; lowest-RTT pick.
- `Sources/TuneSyncCore/Models.swift` — `StateMessage.applyAtMs: Int64?` (additive, optional). `StateMessage.adOnHost: Bool?` (additive). `PingMessage`/`PongMessage` extended with `t0`, `t1`, `t2` timestamps.
- `Sources/TuneSyncCore/SyncEngine.swift` — emit `applyAtMs` on outbound state; expose `applyLeadMs` (default 300); ad-on-host propagation; per-peer offset lookup.
- `Sources/TuneSyncCore/PeerMesh.swift` — feed ping/pong samples into a per-peer `ClockSync`; expose `peerOffsetMs(_:) -> Int?`. Adjust ping/pong wire shape.
- `Sources/TuneSync/InjectedJS.swift` — `tunesyncApplyState(videoId, t, playing, atMs, adOnHost)`. Soft drift correction loop. Mute/pause when `adOnHost=true`.
- `Sources/TuneSync/PlayerController.swift` — pass through `applyAtMs` and `adOnHost` to JS.
- Tests: `Tests/TuneSyncCoreTests/ClockSyncTests.swift`, `SyncEngineApplyAtTests.swift`.

---

## Task 1: ClockSync pure module

**Files:**
- Create: `Sources/TuneSyncCore/ClockSync.swift`
- Test: `Tests/TuneSyncCoreTests/ClockSyncTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import TuneSyncCore

final class ClockSyncTests: XCTestCase {
    func testOffsetAndRttFromSingleSample() {
        let cs = ClockSync(windowSize: 5)
        // Peer is +1000ms ahead. RTT = 100ms. So peer.t0 = 0,
        // local receives at t1 = 1050 (peer's clock would be 50, ours +1000),
        // sends pong at t2 = 1052, peer gets back at t3 = 102.
        // From peer's POV: offset = ((1050-0) + (1052-102))/2 = 1000. RTT = 100.
        cs.recordSample(t0: 0, t1: 1050, t2: 1052, t3: 102)
        XCTAssertEqual(cs.estimatedOffsetMs(), 1000)
        XCTAssertEqual(cs.estimatedRttMs(), 100)
    }

    func testWindowPicksLowestRtt() {
        let cs = ClockSync(windowSize: 5)
        cs.recordSample(t0: 0, t1: 1050, t2: 1052, t3: 102)   // RTT 100
        cs.recordSample(t0: 200, t1: 1700, t2: 1701, t3: 700) // RTT 499
        XCTAssertEqual(cs.estimatedOffsetMs(), 1000) // first sample wins
        XCTAssertEqual(cs.estimatedRttMs(), 100)
    }

    func testEmptyReturnsZero() {
        let cs = ClockSync(windowSize: 5)
        XCTAssertEqual(cs.estimatedOffsetMs(), 0)
        XCTAssertEqual(cs.estimatedRttMs(), 0)
    }

    func testWindowRolls() {
        let cs = ClockSync(windowSize: 2)
        cs.recordSample(t0: 0, t1: 100, t2: 100, t3: 100)     // RTT 0, offset 50
        cs.recordSample(t0: 0, t1: 200, t2: 200, t3: 200)     // RTT 0, offset 100
        cs.recordSample(t0: 0, t1: 300, t2: 300, t3: 300)     // RTT 0, offset 150
        // Only last 2 retained.
        XCTAssertEqual(cs.estimatedOffsetMs(), 100) // tie on rtt → first kept (200)
    }
}
```

Run: `swift test --filter ClockSyncTests` — expect FAIL.

- [ ] **Step 2: Implement ClockSync**

```swift
import Foundation

public final class ClockSync {
    public struct Sample: Equatable {
        public let offsetMs: Int
        public let rttMs: Int
    }

    private var samples: [Sample] = []
    private let windowSize: Int

    public init(windowSize: Int = 5) {
        self.windowSize = windowSize
    }

    /// NTP-style sample.
    /// t0 = peer wallclock when ping sent
    /// t1 = our wallclock when ping received
    /// t2 = our wallclock when pong sent
    /// t3 = peer wallclock when pong received
    public func recordSample(t0: Int64, t1: Int64, t2: Int64, t3: Int64) {
        let rtt = Int((t3 - t0) - (t2 - t1))
        let offset = Int(((t1 - t0) + (t2 - t3)) / 2)
        samples.append(Sample(offsetMs: offset, rttMs: rtt))
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
    }

    public func estimatedOffsetMs() -> Int {
        guard let best = samples.min(by: { $0.rttMs < $1.rttMs }) else { return 0 }
        return best.offsetMs
    }

    public func estimatedRttMs() -> Int {
        guard let best = samples.min(by: { $0.rttMs < $1.rttMs }) else { return 0 }
        return best.rttMs
    }
}
```

Run: `swift test --filter ClockSyncTests` — PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSyncCore/ClockSync.swift Tests/TuneSyncCoreTests/ClockSyncTests.swift
git commit -m "feat(sync): ClockSync NTP-style offset/RTT estimator"
```

---

## Task 2: Extend wire protocol

**Files:**
- Modify: `Sources/TuneSyncCore/Models.swift`
- Test: extend `Tests/TuneSyncCoreTests/ModelsTests.swift`

- [ ] **Step 1: Add fields to existing types**

`StateMessage` gains two optional fields:

```swift
public struct StateMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let ts: Int64
    public let videoId: String
    public let t: Double
    public let playing: Bool
    public let clientMs: Int64?
    public let host: Bool?
    public let applyAtMs: Int64?     // sender's wallclock target
    public let adOnHost: Bool?       // true if host is currently in an ad

    public init(senderId: String, ts: Int64, videoId: String, t: Double, playing: Bool,
                clientMs: Int64? = nil, host: Bool? = nil,
                applyAtMs: Int64? = nil, adOnHost: Bool? = nil) {
        self.senderId = senderId
        self.ts = ts
        self.videoId = videoId
        self.t = t
        self.playing = playing
        self.clientMs = clientMs
        self.host = host
        self.applyAtMs = applyAtMs
        self.adOnHost = adOnHost
    }
}
```

`PingMessage` and `PongMessage` carry the four NTP timestamps:

```swift
public struct PingMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let nonce: Int64
    public let t0: Int64   // sender wallclock at send

    public init(senderId: String, nonce: Int64, t0: Int64 = 0) {
        self.senderId = senderId
        self.nonce = nonce
        self.t0 = t0
    }
}

public struct PongMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let nonce: Int64
    public let t0: Int64    // echoed back from ping
    public let t1: Int64    // receiver wallclock at receive
    public let t2: Int64    // receiver wallclock at send

    public init(senderId: String, nonce: Int64, t0: Int64 = 0, t1: Int64 = 0, t2: Int64 = 0) {
        self.senderId = senderId
        self.nonce = nonce
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
    }
}
```

Defaults of 0 keep existing call sites compiling.

- [ ] **Step 2: Add round-trip tests**

Add to `Tests/TuneSyncCoreTests/ModelsTests.swift`:

```swift
func testStateMessageWithApplyAtRoundTrip() throws {
    let original = SyncMessage.state(StateMessage(
        senderId: "A", ts: 1, videoId: "vid", t: 12.5, playing: true,
        clientMs: 100, host: true, applyAtMs: 400, adOnHost: false
    ))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
    XCTAssertEqual(decoded, original)
}

func testPingPongTimestampsRoundTrip() throws {
    let ping = SyncMessage.ping(PingMessage(senderId: "A", nonce: 7, t0: 100))
    let pong = SyncMessage.pong(PongMessage(senderId: "B", nonce: 7, t0: 100, t1: 150, t2: 152))
    for m in [ping, pong] {
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        XCTAssertEqual(decoded, m)
    }
}
```

- [ ] **Step 3: Run tests + build**

```bash
swift test
swift build
```

All pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/TuneSyncCore/Models.swift Tests/TuneSyncCoreTests/ModelsTests.swift
git commit -m "feat(sync): wire fields for applyAtMs, adOnHost, ping/pong NTP timestamps"
```

---

## Task 3: PeerMesh wires ping/pong timestamps + per-peer offset

**Files:**
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`

- [ ] **Step 1: Track per-peer ClockSync**

Add to `PeerConn` struct:

```swift
var clockSync = ClockSync(windowSize: 5)
```

- [ ] **Step 2: Update outbound ping in `tickLiveness`**

Where the timer creates the ping (`SyncMessage.ping(PingMessage(...))`), set `t0` to current ms:

```swift
let nowMs = Int64(now.timeIntervalSince1970 * 1000)
let msg = SyncMessage.ping(PingMessage(senderId: senderId, nonce: nonceCounter, t0: nowMs))
```

- [ ] **Step 3: Update inbound `.ping` handler in `handleIncomingBytes`**

Replace the ping handler so the pong echoes `t0`, sets `t1` to receive time, `t2` to send time:

```swift
case .ping(let p):
    guard let id = existingPeerId ?? peerId(forEndpoint: endpoint) else { continue }
    let t1 = Int64(Date().timeIntervalSince1970 * 1000)
    let t2 = Int64(Date().timeIntervalSince1970 * 1000)
    let reply = SyncMessage.pong(PongMessage(senderId: senderId, nonce: p.nonce, t0: p.t0, t1: t1, t2: t2))
    if let data = try? JSONEncoder().encode(reply) {
        let frame = FrameCodec.encode(data)
        peers[id]?.connection.send(content: frame, completion: .contentProcessed { _ in })
    }
```

- [ ] **Step 4: Update inbound `.pong` handler**

```swift
case .pong(let p):
    guard let id = existingPeerId ?? peerId(forEndpoint: endpoint),
          var pc = peers[id],
          let nonce = pc.lastPingNonce, nonce == p.nonce,
          let sentAt = pc.lastPingAt else { continue }
    let rttMs = Int(Date().timeIntervalSince(sentAt) * 1000)
    pc.lastPongMs = rttMs
    pc.lastPingNonce = nil
    pc.lastPingAt = nil
    let t3 = Int64(Date().timeIntervalSince1970 * 1000)
    pc.clockSync.recordSample(t0: p.t0, t1: p.t1, t2: p.t2, t3: t3)
    peers[id] = pc
```

- [ ] **Step 5: Public lookup**

```swift
public func peerOffsetMs(senderId id: String) -> Int? {
    return queue.sync {
        return peers[id]?.clockSync.estimatedOffsetMs()
    }
}
```

- [ ] **Step 6: Build + test**

```bash
swift test
swift build
```

All pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift
git commit -m "feat(sync): per-peer ClockSync fed by ping/pong NTP samples"
```

---

## Task 4: SyncEngine emits applyAtMs

**Files:**
- Modify: `Sources/TuneSyncCore/SyncEngine.swift`
- Test: `Tests/TuneSyncCoreTests/SyncEngineApplyAtTests.swift`

- [ ] **Step 1: Add `applyLeadMs` config**

In `SyncEngine.init`, add a parameter `applyLeadMs: Int = 300`. Store as `private let applyLeadMs: Int`.

- [ ] **Step 2: Update `buildStateMessage`**

```swift
private func buildStateMessage(_ s: PlayerState) -> SyncMessage {
    let ts = clock.tick()
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    return SyncMessage.state(StateMessage(
        senderId: senderId, ts: ts,
        videoId: s.videoId, t: s.t, playing: s.playing,
        clientMs: nowMs,
        host: role == .host,
        applyAtMs: nowMs + Int64(applyLeadMs),
        adOnHost: adShowing && role == .host
    ))
}
```

- [ ] **Step 3: Update `handleRemote` apply path**

Replace the latency-comp block with applyAt translation. The receiver needs to know peer offset. Add a stored callback:

```swift
public var peerOffsetLookup: ((String) -> Int?)? = nil
```

In `handleRemote` `.state` case, after `lastApplied = key`:

```swift
let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
var effectiveT = s.t
var compNote: String? = nil
let offsetMs = peerOffsetLookup?(s.senderId) ?? 0

if let applyAt = s.applyAtMs {
    // applyAt is in the sender's clock; translate to local.
    let localTargetMs = applyAt - Int64(offsetMs)
    let waitMs = localTargetMs - nowMs
    if s.playing {
        effectiveT += Double(max(0, waitMs)) / 1000.0
    }
    compNote = "applyAt+\(waitMs)ms (offset:\(offsetMs))"
} else if s.playing, let cms = s.clientMs {
    // Legacy fallback for pre-spec peers.
    let elapsed = nowMs - cms - Int64(offsetMs)
    if elapsed > 0 && elapsed < 800 {
        effectiveT += Double(elapsed) / 1000.0
        compNote = "+\(elapsed)ms latency comp"
    }
}

applyStateImpl(PlayerState(videoId: s.videoId, t: effectiveT, playing: s.playing))
```

(Replace the previous `s.clientMs` block — keep history append unchanged.)

- [ ] **Step 4: Test applyAt math**

Create `Tests/TuneSyncCoreTests/SyncEngineApplyAtTests.swift`:

```swift
import XCTest
@testable import TuneSyncCore

final class SyncEngineApplyAtTests: XCTestCase {
    func testApplyAtAdvancesTPositionForFutureTarget() {
        var applied: PlayerState?
        let engine = SyncEngine(
            senderId: "self",
            broadcast: { _ in },
            applyState: { applied = $0 }
        )
        engine.peerOffsetLookup = { _ in 0 }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = SyncMessage.state(StateMessage(
            senderId: "host", ts: 1,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs, host: true,
            applyAtMs: nowMs + 200,
            adOnHost: false
        ))
        engine.handleRemote(msg)
        // 200ms in future; t should be advanced by ~0.2 because peer is playing.
        guard let a = applied else { return XCTFail("not applied") }
        XCTAssertEqual(a.t, 10.2, accuracy: 0.05)
    }

    func testOffsetSubtractedFromTarget() {
        var applied: PlayerState?
        let engine = SyncEngine(
            senderId: "self",
            broadcast: { _ in },
            applyState: { applied = $0 }
        )
        // Peer clock is +500ms ahead. Their applyAt = nowMs+700 means
        // local target = nowMs+200.
        engine.peerOffsetLookup = { _ in 500 }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = SyncMessage.state(StateMessage(
            senderId: "host", ts: 1,
            videoId: "vid", t: 5.0, playing: true,
            clientMs: nowMs, host: true,
            applyAtMs: nowMs + 700,
            adOnHost: false
        ))
        engine.handleRemote(msg)
        guard let a = applied else { return XCTFail("not applied") }
        XCTAssertEqual(a.t, 5.2, accuracy: 0.05)
    }
}
```

- [ ] **Step 5: Run tests + build**

```bash
swift test
swift build
```

All pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/TuneSyncCore/SyncEngine.swift Tests/TuneSyncCoreTests/SyncEngineApplyAtTests.swift
git commit -m "feat(sync): SyncEngine emits applyAtMs and translates by peer offset"
```

---

## Task 5: Wire SyncEngine to PeerMesh's offset lookup

**Files:**
- Modify: `Sources/TuneSync/ContentView.swift` (where SyncEngine is constructed)

- [ ] **Step 1: Wire callback**

Find where `SyncEngine` is instantiated in `AppRuntime` (search for `SyncEngine(`). Immediately after creation, add:

```swift
syncEngine.peerOffsetLookup = { [weak mesh] senderId in
    mesh?.peerOffsetMs(senderId: senderId)
}
```

(Adjust the local property name; it may be `engine`, `sync`, or similar.)

- [ ] **Step 2: Build**

`swift build` — clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSync/ContentView.swift
git commit -m "feat(sync): wire SyncEngine peer-offset lookup to PeerMesh"
```

---

## Task 6: Inject applyAtMs + adOnHost into JS

**Files:**
- Modify: `Sources/TuneSync/InjectedJS.swift`
- Modify: `Sources/TuneSync/PlayerController.swift`

- [ ] **Step 1: Update `applyState` to pass new params**

In `Sources/TuneSync/PlayerController.swift`, change `applyState` signature on the controller and the JS bridge:

```swift
public func applyState(_ state: PlayerState, applyAtMs: Int64? = nil, adOnHost: Bool = false) {
    guard let wv = webView else { return }
    let atMs = applyAtMs.map { String($0) } ?? "null"
    let ad = adOnHost ? "true" : "false"
    let js = "window.tunesyncApplyState && window.tunesyncApplyState(\(jsString(state.videoId)), \(state.t), \(state.playing), \(atMs), \(ad));"
    wv.evaluateJavaScript(js) { _, error in
        if let error {
            Log.player.error("applyState JS error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

The existing `SyncEngine` callback path passes a plain `PlayerState`. We need the engine to emit `applyAtMs` and `adOnHost` as well. Adjust: change `SyncEngine`'s `applyState` callback type to accept those params. To avoid a wide signature change, expose two new properties on `PlayerController` that the engine sets right before calling `applyState`:

Actually simpler: the engine knows applyAt + adOnHost in `handleRemote`. Replace the call site `applyStateImpl(PlayerState(...))` with `applyStateImpl2?(PlayerState(...), localTargetMs, s.adOnHost ?? false) ?? applyStateImpl(...)`.

Concrete: in `SyncEngine`, add an alternate apply hook:

```swift
public var applyStateExtended: ((PlayerState, Int64?, Bool) -> Void)? = nil
```

In `handleRemote` `.state`, where you currently call `applyStateImpl(...)`:

```swift
let localTargetMs: Int64? = s.applyAtMs.map { $0 - Int64(offsetMs) }
if let ext = applyStateExtended {
    ext(PlayerState(videoId: s.videoId, t: effectiveT, playing: s.playing), localTargetMs, s.adOnHost ?? false)
} else {
    applyStateImpl(PlayerState(videoId: s.videoId, t: effectiveT, playing: s.playing))
}
```

In `AppRuntime` setup (Task 5 area), set:

```swift
syncEngine.applyStateExtended = { [weak controller] state, atMs, adOnHost in
    DispatchQueue.main.async {
        controller?.applyState(state, applyAtMs: atMs, adOnHost: adOnHost)
    }
}
```

- [ ] **Step 2: Update `InjectedJS.swift` `tunesyncApplyState`**

Replace the function with:

```javascript
window.tunesyncApplyState = function (videoId, t, playing, atMs, adOnHost) {
    var v = getVideo();
    if (!v) return false;
    var current = getVideoId();
    var changed = false;

    // Ad-on-host: pause + mute regardless of other params.
    if (adOnHost) {
        if (!v.muted) { v.muted = true; }
        if (!v.paused) { v.pause(); }
        lastAppliedAt = Date.now();
        return true;
    } else {
        if (v.muted) { v.muted = false; }
    }

    if (videoId && videoId !== current) {
        lastAppliedAt = Date.now();
        lastAppliedVideoId = videoId;
        var dest = "https://music.youtube.com/watch?v=" + encodeURIComponent(videoId) + "&t=" + Math.floor(t || 0);
        window.location.href = dest;
        return true;
    }

    function doApply() {
        var diff = (typeof t === "number") ? (v.currentTime || 0) - t : 0;
        var absDiff = Math.abs(diff);
        if (absDiff > 0.5) {
            try { v.currentTime = t; changed = true; } catch (e) {}
            v.playbackRate = 1.0;
        } else if (absDiff > 0.05) {
            // Soft drift correction via playbackRate.
            v.playbackRate = (diff > 0) ? 0.98 : 1.02;
            // Restore rate after we've absorbed the drift (~rate * window).
            setTimeout(function () { v.playbackRate = 1.0; }, Math.max(200, absDiff * 1000 * 50));
        } else {
            v.playbackRate = 1.0;
        }
        if (playing && v.paused) { v.play().catch(function () {}); changed = true; }
        if (!playing && !v.paused) { v.pause(); changed = true; }
        if (changed) {
            lastAppliedAt = Date.now();
            lastAppliedVideoId = videoId || current;
        }
    }

    if (typeof atMs === "number" && atMs !== null) {
        var wait = atMs - Date.now();
        if (wait > 0 && wait < 1000) {
            setTimeout(doApply, wait);
            return true;
        }
    }
    doApply();
    return true;
};
```

- [ ] **Step 3: Build**

```bash
swift build
```

Clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/TuneSync/InjectedJS.swift Sources/TuneSync/PlayerController.swift Sources/TuneSyncCore/SyncEngine.swift Sources/TuneSync/ContentView.swift
git commit -m "feat(sync): scheduled apply + soft drift correction + ad-on-host mute"
```

---

## Task 7: Diagnostics surface offset/RTT per peer

**Files:**
- Modify: `Sources/TuneSyncCore/MeshDiagnostics.swift`
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`
- Modify: `Sources/TuneSync/ConnectionManagerView.swift`

- [ ] **Step 1: Add fields to `PeerLiveness`**

```swift
public struct PeerLiveness: Equatable, Sendable {
    public let senderId: String
    public let lastSeen: Date
    public let lastPongMs: Int?
    public let connDurationS: TimeInterval
    public let offsetMs: Int
    public let rttMs: Int

    public init(senderId: String, lastSeen: Date, lastPongMs: Int?, connDurationS: TimeInterval, offsetMs: Int = 0, rttMs: Int = 0) {
        self.senderId = senderId
        self.lastSeen = lastSeen
        self.lastPongMs = lastPongMs
        self.connDurationS = connDurationS
        self.offsetMs = offsetMs
        self.rttMs = rttMs
    }
}
```

- [ ] **Step 2: Populate in `currentDiagnostics`**

```swift
PeerLiveness(
    senderId: p.id,
    lastSeen: p.lastSeen,
    lastPongMs: p.lastPongMs,
    connDurationS: now.timeIntervalSince(p.connectedAt),
    offsetMs: p.clockSync.estimatedOffsetMs(),
    rttMs: p.clockSync.estimatedRttMs()
)
```

- [ ] **Step 3: Render in `ConnectionManagerView`**

In the per-peer ForEach inside `diagnosticsSection`, change the value to:

```swift
let rtt = p.rttMs > 0 ? "\(p.rttMs)ms" : (p.lastPongMs.map { "\($0)ms" } ?? "—")
let off = "\(p.offsetMs)ms"
let dur = Int(p.connDurationS)
diagRow(String(p.senderId.prefix(8)), "rtt:\(rtt) off:\(off) up:\(dur)s")
```

- [ ] **Step 4: Build + test**

```bash
swift test
swift build
```

All pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/TuneSyncCore/MeshDiagnostics.swift Sources/TuneSyncCore/PeerMesh.swift Sources/TuneSync/ConnectionManagerView.swift
git commit -m "feat(diagnostics): surface per-peer clock offset and RTT"
```

---

## Task 8: Two-Mac manual test scenarios

**Files:**
- Modify: `docs/TESTING.md`

- [ ] **Step 1: Append section**

```markdown
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

1. Wait for an ad on host (or switch to a free signed-out account that gets ads more often).
2. Guest's `tunesync` should mute + pause within 1 s of ad start.
3. When ad ends, guest unmutes and resumes in sync.
```

- [ ] **Step 2: Commit**

```bash
git add docs/TESTING.md
git commit -m "docs: sync-tightness manual test scenarios"
```

---

## Task 9: Version bump

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Bump 0.2.8 → 0.2.9**

`sed -i '' 's/0\.2\.8/0.2.9/g' Makefile`

- [ ] **Step 2: Commit**

```bash
git add Makefile
git commit -m "build: bump to 0.2.9 for sync-tightness release"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| Clock-offset estimator (NTP-style) | 1 |
| Wire protocol additions (applyAtMs, t0/t1/t2, adOnHost) | 2 |
| PeerMesh feeds offset, exposes lookup | 3 |
| SyncEngine emits applyAtMs + uses offset | 4, 5 |
| Scheduled apply + soft drift in JS | 6 |
| Skip-ad detector (folded in) | 4 (engine emits adOnHost), 6 (JS handles) |
| Diagnostics offset + RTT | 7 |
| Manual test scenarios | 8 |

**Placeholder scan:** No TBDs. Every step has concrete code.

**Type consistency:** `applyAtMs: Int64?`, `adOnHost: Bool?`, `peerOffsetMs(senderId:) -> Int?`, `peerOffsetLookup`, `applyStateExtended`, `PeerLiveness.offsetMs/rttMs` — names match across tasks.
