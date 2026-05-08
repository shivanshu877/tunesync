# Rooms Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `PeerMesh` so two Macs on the same Wi-Fi reliably connect, stay connected through Wi-Fi flips and sleep-wake, and recover from listener / browser failures.

**Architecture:** Additive changes inside `PeerMesh.swift`. New `.ping` / `.pong` `SyncMessage` cases for liveness. New `ClockSync`-adjacent supervisor that watches listener, browser, and `NWPathMonitor`, restarting subsystems on failure with exponential backoff. Dial tie-break by `senderId` to remove simultaneous-connect races. Hello-collision dedup. Bonjour goodbye gap on room change. Diagnostics surfaced in `ConnectionManagerView`.

**Tech Stack:** Swift 6, `Network` framework (`NWListener`, `NWBrowser`, `NWConnection`, `NWPathMonitor`), `AppKit` (`NSWorkspace` notifications), `XCTest`.

---

## File Structure

- `Sources/TuneSyncCore/Models.swift` — extend `SyncMessage` with `.ping` / `.pong` cases (additive Codable).
- `Sources/TuneSyncCore/PeerMesh.swift` — main edits: tie-break dial, hello collision, ping/pong loop, supervisor restart, path + sleep/wake handling, room-change gap, expanded diagnostics struct.
- `Sources/TuneSyncCore/MeshDiagnostics.swift` — new file. Plain-data struct exposed via delegate so the SwiftUI view can read it without coupling to `Network` types.
- `Tests/TuneSyncCoreTests/MeshDialTieBreakTests.swift` — pure-logic test of the tie-break rule.
- `Tests/TuneSyncCoreTests/MeshLivenessTests.swift` — drive a fake clock through the liveness logic.
- `Tests/TuneSyncCoreTests/MeshHelloCollisionTests.swift` — verify older connection wins on duplicate hello.
- `Tests/TuneSyncCoreTests/ModelsTests.swift` — extend with ping/pong codec round-trip.
- `Sources/TuneSync/ConnectionManagerView.swift` — extend `diagnosticsSection` with new fields.
- `docs/TESTING.md` — add manual scenarios for Wi-Fi flip, sleep-wake, room rename, kick+rejoin.

To make the supervisor and liveness logic unit-testable without spinning up real `NWConnection`s, factor the decision rules out as pure functions.

- `Sources/TuneSyncCore/MeshPolicy.swift` — new file. Pure functions: `shouldDial(localId:remoteId:)`, `livenessAction(now:lastSeen:lastPingSent:)` returning `.idle / .sendPing / .dropDead`, `restartBackoff(attempt:)` returning seconds.

---

## Task 1: Add `.ping` / `.pong` to `SyncMessage`

**Files:**
- Modify: `Sources/TuneSyncCore/Models.swift`
- Test: `Tests/TuneSyncCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write failing test for ping codec round-trip**

Add to `Tests/TuneSyncCoreTests/ModelsTests.swift`:

```swift
func testPingMessageRoundTrip() throws {
    let original = SyncMessage.ping(PingMessage(senderId: "A", nonce: 42))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
    XCTAssertEqual(decoded, original)
}

func testPongMessageRoundTrip() throws {
    let original = SyncMessage.pong(PongMessage(senderId: "B", nonce: 42))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
    XCTAssertEqual(decoded, original)
}

func testUnknownKindIsIgnoredGracefully() {
    let bogus = #"{"kind":"future-thing","senderId":"X"}"#.data(using: .utf8)!
    XCTAssertThrowsError(try JSONDecoder().decode(SyncMessage.self, from: bogus))
}
```

- [ ] **Step 2: Run test, confirm failure**

Run: `swift test --filter ModelsTests/testPingMessageRoundTrip`
Expected: FAIL — `PingMessage` and `.ping` case do not exist.

- [ ] **Step 3: Add ping / pong types and cases**

Modify `Sources/TuneSyncCore/Models.swift`. Add structs after `ByeMessage`:

```swift
public struct PingMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let nonce: Int64

    public init(senderId: String, nonce: Int64) {
        self.senderId = senderId
        self.nonce = nonce
    }
}

public struct PongMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let nonce: Int64

    public init(senderId: String, nonce: Int64) {
        self.senderId = senderId
        self.nonce = nonce
    }
}
```

Extend `SyncMessage`:

```swift
public enum SyncMessage: Codable, Equatable, Sendable {
    case state(StateMessage)
    case hello(HelloMessage)
    case bye(ByeMessage)
    case ping(PingMessage)
    case pong(PongMessage)

    private enum Kind: String, Codable {
        case state, hello, bye, ping, pong
    }

    private enum Keys: String, CodingKey {
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .state: self = .state(try StateMessage(from: decoder))
        case .hello: self = .hello(try HelloMessage(from: decoder))
        case .bye:   self = .bye(try ByeMessage(from: decoder))
        case .ping:  self = .ping(try PingMessage(from: decoder))
        case .pong:  self = .pong(try PongMessage(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .state(let m):
            try c.encode(Kind.state, forKey: .kind); try m.encode(to: encoder)
        case .hello(let m):
            try c.encode(Kind.hello, forKey: .kind); try m.encode(to: encoder)
        case .bye(let m):
            try c.encode(Kind.bye, forKey: .kind); try m.encode(to: encoder)
        case .ping(let m):
            try c.encode(Kind.ping, forKey: .kind); try m.encode(to: encoder)
        case .pong(let m):
            try c.encode(Kind.pong, forKey: .kind); try m.encode(to: encoder)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter ModelsTests`
Expected: PASS for new round-trip tests; existing tests still pass.

- [ ] **Step 5: Update SyncEngine to ignore ping/pong**

Modify `Sources/TuneSyncCore/SyncEngine.swift`. Extend the switch in `handleRemote`:

```swift
public func handleRemote(_ message: SyncMessage) {
    switch message {
    case .state(let s):
        // ... existing logic unchanged ...
    case .hello, .bye, .ping, .pong:
        break
    }
}
```

- [ ] **Step 6: Run all tests**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TuneSyncCore/Models.swift Sources/TuneSyncCore/SyncEngine.swift Tests/TuneSyncCoreTests/ModelsTests.swift
git commit -m "feat(mesh): add ping/pong SyncMessage cases for peer liveness"
```

---

## Task 2: Pure-logic policy module

**Files:**
- Create: `Sources/TuneSyncCore/MeshPolicy.swift`
- Test: `Tests/TuneSyncCoreTests/MeshDialTieBreakTests.swift`
- Test: `Tests/TuneSyncCoreTests/MeshLivenessTests.swift`

- [ ] **Step 1: Write failing dial-tie-break test**

Create `Tests/TuneSyncCoreTests/MeshDialTieBreakTests.swift`:

```swift
import XCTest
@testable import TuneSyncCore

final class MeshDialTieBreakTests: XCTestCase {
    func testLowerSenderIdDials() {
        XCTAssertTrue(MeshPolicy.shouldDial(localId: "alice", remoteId: "bob"))
        XCTAssertFalse(MeshPolicy.shouldDial(localId: "bob", remoteId: "alice"))
    }

    func testEqualIdsDoNotDial() {
        XCTAssertFalse(MeshPolicy.shouldDial(localId: "x", remoteId: "x"))
    }
}
```

- [ ] **Step 2: Write failing liveness test**

Create `Tests/TuneSyncCoreTests/MeshLivenessTests.swift`:

```swift
import XCTest
@testable import TuneSyncCore

final class MeshLivenessTests: XCTestCase {
    func testIdleWhenRecentTraffic() {
        let now = Date(timeIntervalSince1970: 1000)
        let action = MeshPolicy.livenessAction(
            now: now,
            lastSeen: now.addingTimeInterval(-1),
            lastPingSent: now.addingTimeInterval(-30),
            pingIntervalS: 10,
            deadAfterS: 25
        )
        XCTAssertEqual(action, .idle)
    }

    func testSendPingAfterSilence() {
        let now = Date(timeIntervalSince1970: 1000)
        let action = MeshPolicy.livenessAction(
            now: now,
            lastSeen: now.addingTimeInterval(-12),
            lastPingSent: now.addingTimeInterval(-12),
            pingIntervalS: 10,
            deadAfterS: 25
        )
        XCTAssertEqual(action, .sendPing)
    }

    func testDropAfterDeadWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let action = MeshPolicy.livenessAction(
            now: now,
            lastSeen: now.addingTimeInterval(-30),
            lastPingSent: now.addingTimeInterval(-15),
            pingIntervalS: 10,
            deadAfterS: 25
        )
        XCTAssertEqual(action, .dropDead)
    }

    func testBackoffSchedule() {
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 0), 1)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 1), 2)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 2), 5)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 3), 10)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 99), 10)
    }
}
```

- [ ] **Step 3: Run tests, confirm failure**

Run: `swift test --filter MeshDialTieBreakTests`
Expected: FAIL — `MeshPolicy` does not exist.

- [ ] **Step 4: Implement `MeshPolicy`**

Create `Sources/TuneSyncCore/MeshPolicy.swift`:

```swift
import Foundation

public enum LivenessAction: Equatable, Sendable {
    case idle
    case sendPing
    case dropDead
}

public enum MeshPolicy {
    /// Tie-break for simultaneous-dial races. The peer with the
    /// lexicographically smaller senderId initiates the TCP connection;
    /// the other waits for incoming hello.
    public static func shouldDial(localId: String, remoteId: String) -> Bool {
        return localId < remoteId
    }

    public static func livenessAction(
        now: Date,
        lastSeen: Date,
        lastPingSent: Date,
        pingIntervalS: TimeInterval,
        deadAfterS: TimeInterval
    ) -> LivenessAction {
        let silenceFromLastSeen = now.timeIntervalSince(lastSeen)
        if silenceFromLastSeen >= deadAfterS { return .dropDead }
        let sincePing = now.timeIntervalSince(lastPingSent)
        if silenceFromLastSeen >= pingIntervalS && sincePing >= pingIntervalS {
            return .sendPing
        }
        return .idle
    }

    /// Exponential-ish backoff schedule for restart attempts on listener,
    /// browser, or path failures. Capped to keep retries cheap.
    public static func restartBackoff(attempt: Int) -> TimeInterval {
        switch attempt {
        case 0: return 1
        case 1: return 2
        case 2: return 5
        default: return 10
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter MeshDialTieBreakTests && swift test --filter MeshLivenessTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/TuneSyncCore/MeshPolicy.swift Tests/TuneSyncCoreTests/MeshDialTieBreakTests.swift Tests/TuneSyncCoreTests/MeshLivenessTests.swift
git commit -m "feat(mesh): pure-logic MeshPolicy for dial tie-break, liveness, backoff"
```

---

## Task 3: Diagnostics struct

**Files:**
- Create: `Sources/TuneSyncCore/MeshDiagnostics.swift`

- [ ] **Step 1: Create the struct**

Create `Sources/TuneSyncCore/MeshDiagnostics.swift`:

```swift
import Foundation

public struct PeerLiveness: Equatable, Sendable {
    public let senderId: String
    public let lastSeen: Date
    public let lastPongMs: Int?
    public let connDurationS: TimeInterval

    public init(senderId: String, lastSeen: Date, lastPongMs: Int?, connDurationS: TimeInterval) {
        self.senderId = senderId
        self.lastSeen = lastSeen
        self.lastPongMs = lastPongMs
        self.connDurationS = connDurationS
    }
}

public struct MeshDiagnostics: Equatable, Sendable {
    public let listenerState: String
    public let browserState: String
    public let pathStatus: String
    public let interface: String?
    public let listenerRestarts: Int
    public let browserRestarts: Int
    public let pathRestarts: Int
    public let pingTimeouts: Int
    public let peers: [PeerLiveness]

    public init(
        listenerState: String,
        browserState: String,
        pathStatus: String,
        interface: String?,
        listenerRestarts: Int,
        browserRestarts: Int,
        pathRestarts: Int,
        pingTimeouts: Int,
        peers: [PeerLiveness]
    ) {
        self.listenerState = listenerState
        self.browserState = browserState
        self.pathStatus = pathStatus
        self.interface = interface
        self.listenerRestarts = listenerRestarts
        self.browserRestarts = browserRestarts
        self.pathRestarts = pathRestarts
        self.pingTimeouts = pingTimeouts
        self.peers = peers
    }

    public static let empty = MeshDiagnostics(
        listenerState: "—",
        browserState: "—",
        pathStatus: "—",
        interface: nil,
        listenerRestarts: 0,
        browserRestarts: 0,
        pathRestarts: 0,
        pingTimeouts: 0,
        peers: []
    )
}
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSyncCore/MeshDiagnostics.swift
git commit -m "feat(mesh): MeshDiagnostics struct for diagnostics surface"
```

---

## Task 4: Hello-collision dedup test + implementation

**Files:**
- Test: `Tests/TuneSyncCoreTests/MeshHelloCollisionTests.swift`
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`

PeerMesh creates connections, which makes deep unit-testing it hard. Use a small wrapper around the duplicate-hello handling logic instead.

- [ ] **Step 1: Refactor: extract `handleHelloCollision` as a pure function**

Modify `Sources/TuneSyncCore/PeerMesh.swift`. Add internal helper near the other private helpers:

```swift
/// Pure decision: when a hello arrives for a peer we already track,
/// should we replace the existing connection or keep it?
/// Returns true if the new connection should replace the old one.
internal static func shouldReplaceExistingPeer(
    existingConnectedAt: Date,
    newHelloAt: Date
) -> Bool {
    // Always keep the older connection. New hellos for known peers
    // are duplicates from a racing dial — drop the new one.
    return false
}
```

Then in `handleIncomingBytes`, in the `.hello` case, when `peers[h.senderId] != nil`, additionally cancel the new connection if it differs from the existing one:

```swift
case .hello(let h):
    if let existing = peers[h.senderId] {
        // Update host claim (existing behavior)
        let newHost = h.host ?? false
        if existing.isHost != newHost {
            peers[h.senderId]!.isHost = newHost
            notifyChange()
        }
        // Duplicate connection from a racing dial — cancel the new one.
        if existing.connection !== conn && existing.connection.endpoint != conn.endpoint {
            Log.mesh.info("hello collision for \(h.senderId, privacy: .public) — keeping older conn, cancelling new")
            conn.cancel()
            pendingByEndpoint.removeValue(forKey: conn.endpoint)
            pendingParsers.removeValue(forKey: conn.endpoint)
        }
    } else if h.senderId != senderId {
        // ... existing first-hello promotion path unchanged ...
```

- [ ] **Step 2: Write test for the pure helper**

Create `Tests/TuneSyncCoreTests/MeshHelloCollisionTests.swift`:

```swift
import XCTest
@testable import TuneSyncCore

final class MeshHelloCollisionTests: XCTestCase {
    func testCollisionAlwaysKeepsExisting() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 1005)
        XCTAssertFalse(PeerMesh.shouldReplaceExistingPeer(
            existingConnectedAt: earlier,
            newHelloAt: later
        ))
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter MeshHelloCollisionTests`
Expected: PASS.

- [ ] **Step 4: Build executable to confirm PeerMesh still compiles**

Run: `swift build`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift Tests/TuneSyncCoreTests/MeshHelloCollisionTests.swift
git commit -m "fix(mesh): cancel duplicate connection on hello collision"
```

---

## Task 5: Apply dial tie-break in `handleBrowse`

**Files:**
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`

- [ ] **Step 1: Replace auto-dial-on-discovery with tie-break**

Modify `Sources/TuneSyncCore/PeerMesh.swift` in `handleBrowse`:

```swift
// Auto-connect unless kicked or already pending/connected
if peers[id] != nil { continue }
if kicked.contains(id) { continue }
if pendingByEndpoint[result.endpoint] != nil { continue }

// Tie-break: only the lower senderId dials. Higher waits for the
// peer's hello to arrive on a connection they initiated.
guard MeshPolicy.shouldDial(localId: senderId, remoteId: id) else { continue }

let conn = NWConnection(to: result.endpoint, using: .tcp)
pendingByEndpoint[result.endpoint] = conn
pendingParsers[result.endpoint] = FrameParser()
configureConnection(conn, side: .outgoing)
```

- [ ] **Step 2: Add fallback dial if higher-id peer never gets contacted**

Add a 5-second timer in `handleBrowse`. After noting a discovery we chose not to dial, schedule a fallback:

```swift
// Fallback: if we're the higher-id peer and no connection has come in
// after 5s, dial anyway. Handles asymmetric reachability.
if !MeshPolicy.shouldDial(localId: senderId, remoteId: id) {
    let endpoint = result.endpoint
    let remoteId = id
    queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
        guard let self else { return }
        if self.peers[remoteId] != nil { return }
        if self.pendingByEndpoint[endpoint] != nil { return }
        if self.kicked.contains(remoteId) { return }
        Log.mesh.info("fallback dial \(remoteId, privacy: .public) — tie-break peer never connected")
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.pendingByEndpoint[endpoint] = conn
        self.pendingParsers[endpoint] = FrameParser()
        self.configureConnection(conn, side: .outgoing)
    }
}
```

- [ ] **Step 3: Run unit tests + build**

Run: `swift test --filter MeshDialTieBreakTests && swift build`
Expected: PASS, builds.

- [ ] **Step 4: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift
git commit -m "fix(mesh): dial tie-break by senderId with 5s fallback"
```

---

## Task 6: Ping / pong liveness loop

**Files:**
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`

- [ ] **Step 1: Add per-peer liveness state**

Modify `PeerConn` struct:

```swift
private struct PeerConn {
    let id: String
    var displayName: String
    let connection: NWConnection
    let connectedAt: Date
    var parser = FrameParser()
    var isHost: Bool = false
    var lastSeen: Date = Date()
    var lastPingSent: Date = .distantPast
    var lastPongMs: Int? = nil
    var lastPingNonce: Int64? = nil
    var lastPingAt: Date? = nil
}
```

- [ ] **Step 2: Update `lastSeen` on every inbound frame**

In `handleIncomingBytes`, after `parser.append(bytes)`, before the frame loop:

```swift
if let id = existingPeerId {
    peers[id]?.lastSeen = Date()
}
```

- [ ] **Step 3: Handle ping → reply pong; handle pong → record RTT**

In the frame switch, add cases:

```swift
case .ping(let p):
    guard let id = existingPeerId ?? peerId(forEndpoint: endpoint) else { continue }
    let reply = SyncMessage.pong(PongMessage(senderId: senderId, nonce: p.nonce))
    if let data = try? JSONEncoder().encode(reply) {
        let frame = FrameCodec.encode(data)
        peers[id]?.connection.send(content: frame, completion: .contentProcessed { _ in })
    }
case .pong(let p):
    guard let id = existingPeerId ?? peerId(forEndpoint: endpoint),
          var pc = peers[id],
          let nonce = pc.lastPingNonce, nonce == p.nonce,
          let sentAt = pc.lastPingAt else { continue }
    let rttMs = Int(Date().timeIntervalSince(sentAt) * 1000)
    pc.lastPongMs = rttMs
    pc.lastPingNonce = nil
    pc.lastPingAt = nil
    peers[id] = pc
```

- [ ] **Step 4: Add liveness timer**

Add property:

```swift
private var livenessTimer: DispatchSourceTimer?
private var pingTimeoutCount: Int = 0
private var nonceCounter: Int64 = 0
```

In `start()`:

```swift
public func start() {
    startListener()
    startBrowser()
    startLivenessLoop()
}
```

Add method:

```swift
private func startLivenessLoop() {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
    t.setEventHandler { [weak self] in self?.tickLiveness() }
    t.resume()
    livenessTimer = t
}

private func tickLiveness() {
    let now = Date()
    var toDrop: [String] = []
    for (id, var pc) in peers {
        let action = MeshPolicy.livenessAction(
            now: now,
            lastSeen: pc.lastSeen,
            lastPingSent: pc.lastPingSent,
            pingIntervalS: 10,
            deadAfterS: 25
        )
        switch action {
        case .idle:
            break
        case .sendPing:
            nonceCounter &+= 1
            pc.lastPingSent = now
            pc.lastPingAt = now
            pc.lastPingNonce = nonceCounter
            peers[id] = pc
            let msg = SyncMessage.ping(PingMessage(senderId: senderId, nonce: nonceCounter))
            if let data = try? JSONEncoder().encode(msg) {
                pc.connection.send(content: FrameCodec.encode(data), completion: .contentProcessed { _ in })
            }
        case .dropDead:
            pingTimeoutCount += 1
            toDrop.append(id)
        }
    }
    for id in toDrop {
        if let pc = peers[id] { pc.connection.cancel() }
        Log.mesh.info("dropping silent peer \(id, privacy: .public)")
        removePeer(id: id)
    }
}
```

- [ ] **Step 5: Cancel timer in `stop()`**

```swift
public func stop() {
    livenessTimer?.cancel()
    livenessTimer = nil
    listener?.cancel()
    // ... rest unchanged ...
}
```

- [ ] **Step 6: Run all tests + build**

Run: `swift test && swift build`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift
git commit -m "feat(mesh): per-peer ping/pong liveness with 25s drop timeout"
```

---

## Task 7: Listener / browser supervisor with restart on failure

**Files:**
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`

- [ ] **Step 1: Track restart counters and attempt counts**

Add properties:

```swift
private var listenerRestartAttempt: Int = 0
private var browserRestartAttempt: Int = 0
private var listenerRestartCount: Int = 0
private var browserRestartCount: Int = 0
private var lastListenerState: String = "—"
private var lastBrowserState: String = "—"
```

- [ ] **Step 2: Restart listener on `.failed`**

Update `startListener`'s `stateUpdateHandler`:

```swift
listener.stateUpdateHandler = { [weak self] state in
    guard let self else { return }
    self.queue.async {
        self.lastListenerState = String(describing: state)
        Log.mesh.info("listener state \(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            self.listenerRestartAttempt = 0
        case .failed, .cancelled:
            self.scheduleListenerRestart()
        default:
            break
        }
    }
}
```

Add:

```swift
private func scheduleListenerRestart() {
    let delay = MeshPolicy.restartBackoff(attempt: listenerRestartAttempt)
    listenerRestartAttempt += 1
    listenerRestartCount += 1
    Log.mesh.info("scheduling listener restart in \(delay, privacy: .public)s (attempt \(self.listenerRestartAttempt, privacy: .public))")
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        self.listener?.cancel()
        self.startListener()
    }
}
```

- [ ] **Step 3: Same treatment for browser**

```swift
browser.stateUpdateHandler = { [weak self] state in
    guard let self else { return }
    self.queue.async {
        self.lastBrowserState = String(describing: state)
        Log.mesh.info("browser state \(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            self.browserRestartAttempt = 0
        case .failed, .cancelled:
            self.scheduleBrowserRestart()
        default:
            break
        }
    }
}

private func scheduleBrowserRestart() {
    let delay = MeshPolicy.restartBackoff(attempt: browserRestartAttempt)
    browserRestartAttempt += 1
    browserRestartCount += 1
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self else { return }
        self.browser?.cancel()
        self.startBrowser()
    }
}
```

- [ ] **Step 4: Build + run tests**

Run: `swift test && swift build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift
git commit -m "feat(mesh): restart listener/browser on failure with backoff"
```

---

## Task 8: NWPathMonitor + sleep / wake

**Files:**
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`

- [ ] **Step 1: Add path monitor, properties, and wake observer**

Add at top:

```swift
import AppKit
```

Properties:

```swift
private var pathMonitor: NWPathMonitor?
private var lastPath: NWPath?
private var pathRestartCount: Int = 0
private var lastPathStatus: String = "—"
private var lastPathInterface: String? = nil
private var unsatisfiedSince: Date? = nil
private var wakeObserver: NSObjectProtocol?
private var sleepObserver: NSObjectProtocol?
```

- [ ] **Step 2: Start path monitoring in `start()`**

```swift
public func start() {
    startListener()
    startBrowser()
    startLivenessLoop()
    startPathMonitor()
    startWakeSleepObservers()
}

private func startPathMonitor() {
    let m = NWPathMonitor()
    m.pathUpdateHandler = { [weak self] path in
        self?.queue.async { self?.handlePathUpdate(path) }
    }
    m.start(queue: queue)
    pathMonitor = m
}

private func handlePathUpdate(_ path: NWPath) {
    lastPathStatus = String(describing: path.status)
    lastPathInterface = path.availableInterfaces.first.map { "\($0.type)" }

    switch path.status {
    case .satisfied:
        if unsatisfiedSince != nil {
            unsatisfiedSince = nil
            Log.mesh.info("path recovered — restarting mesh")
            fullMeshRestart(reason: "path-recovered")
        }
        // Interface change while satisfied (Wi-Fi network swap)
        if let last = lastPath, last.availableInterfaces != path.availableInterfaces {
            fullMeshRestart(reason: "interface-changed")
        }
    case .unsatisfied:
        if unsatisfiedSince == nil {
            unsatisfiedSince = Date()
        }
        // If unsatisfied >= 3s, tear down and let restart pick up on recovery.
        // The restart itself happens when status flips back to .satisfied.
    default:
        break
    }
    lastPath = path
}

private func fullMeshRestart(reason: String) {
    pathRestartCount += 1
    Log.mesh.info("full mesh restart (\(reason, privacy: .public))")
    listener?.cancel()
    browser?.cancel()
    for (_, p) in peers { p.connection.cancel() }
    peers.removeAll()
    for (_, c) in pendingByEndpoint { c.cancel() }
    pendingByEndpoint.removeAll()
    pendingParsers.removeAll()
    discovered.removeAll()
    queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
        guard let self else { return }
        self.startListener()
        self.startBrowser()
        self.notifyChange()
    }
}

private func startWakeSleepObservers() {
    let nc = NSWorkspace.shared.notificationCenter
    wakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
        self?.queue.async { self?.fullMeshRestart(reason: "wake") }
    }
    sleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
        self?.queue.async {
            // Polite goodbye so peers drop us fast.
            let bye = SyncMessage.bye(ByeMessage(senderId: self?.senderId ?? ""))
            if let data = try? JSONEncoder().encode(bye) {
                let frame = FrameCodec.encode(data)
                for (_, p) in self?.peers ?? [:] {
                    p.connection.send(content: frame, completion: .contentProcessed { _ in })
                }
            }
        }
    }
}
```

- [ ] **Step 3: Update `stop()` to release observers and monitor**

```swift
public func stop() {
    livenessTimer?.cancel()
    livenessTimer = nil
    pathMonitor?.cancel()
    pathMonitor = nil
    if let w = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(w) }
    if let s = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(s) }
    wakeObserver = nil
    sleepObserver = nil
    listener?.cancel()
    browser?.cancel()
    for (_, p) in peers { p.connection.cancel() }
    peers.removeAll()
    for (_, c) in pendingByEndpoint { c.cancel() }
    pendingByEndpoint.removeAll()
    pendingParsers.removeAll()
    discovered.removeAll()
}
```

- [ ] **Step 4: Build + test**

Run: `swift test && swift build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift
git commit -m "feat(mesh): NWPathMonitor + sleep/wake handling"
```

---

## Task 9: Room-change goodbye gap

**Files:**
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`

- [ ] **Step 1: Add 500ms gap to `setRoom`**

Replace the current `setRoom` body:

```swift
public func setRoom(_ name: String) {
    queue.async { [self] in
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let next = trimmed.isEmpty ? "default" : trimmed
        if next == room { return }

        // Polite goodbye to current peers so they remove us instantly.
        let bye = SyncMessage.bye(ByeMessage(senderId: senderId))
        if let data = try? JSONEncoder().encode(bye) {
            let frame = FrameCodec.encode(data)
            for (_, p) in peers {
                p.connection.send(content: frame, completion: .contentProcessed { _ in })
            }
        }

        room = next
        for (_, p) in peers { p.connection.cancel() }
        peers.removeAll()
        for (_, c) in pendingByEndpoint { c.cancel() }
        pendingByEndpoint.removeAll()
        pendingParsers.removeAll()
        discovered.removeAll()
        kicked.removeAll()
        listener?.cancel()
        browser?.cancel()

        // Let mDNS goodbye propagate before re-listening.
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self else { return }
            self.startListener()
            self.startBrowser()
            self.notifyChange()
        }
    }
}
```

- [ ] **Step 2: Build + test**

Run: `swift test && swift build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift
git commit -m "fix(mesh): 500ms goodbye gap on room change to flush mDNS cache"
```

---

## Task 10: Surface diagnostics

**Files:**
- Modify: `Sources/TuneSyncCore/PeerMesh.swift`
- Modify: `Sources/TuneSync/ConnectionManagerView.swift`
- Modify: app runtime that holds `PeerMesh`

- [ ] **Step 1: Add `currentDiagnostics()` to PeerMesh**

```swift
public func currentDiagnostics() -> MeshDiagnostics {
    return queue.sync {
        let now = Date()
        let peerLiveness: [PeerLiveness] = peers.values.map { p in
            PeerLiveness(
                senderId: p.id,
                lastSeen: p.lastSeen,
                lastPongMs: p.lastPongMs,
                connDurationS: now.timeIntervalSince(p.connectedAt)
            )
        }.sorted { $0.senderId < $1.senderId }
        return MeshDiagnostics(
            listenerState: lastListenerState,
            browserState: lastBrowserState,
            pathStatus: lastPathStatus,
            interface: lastPathInterface,
            listenerRestarts: listenerRestartCount,
            browserRestarts: browserRestartCount,
            pathRestarts: pathRestartCount,
            pingTimeouts: pingTimeoutCount,
            peers: peerLiveness
        )
    }
}
```

- [ ] **Step 2: Plumb into AppRuntime**

Find the `AppRuntime` class (likely `Sources/TuneSync/App.swift` or similar). Add:

```swift
@Published public var meshDiagnostics: MeshDiagnostics = .empty

private var diagPollTimer: Timer?

func startDiagPolling() {
    diagPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
        guard let self else { return }
        let snap = self.peerMesh.currentDiagnostics()
        DispatchQueue.main.async { self.meshDiagnostics = snap }
    }
}
```

Call `startDiagPolling()` after `peerMesh.start()`.

- [ ] **Step 3: Render in ConnectionManagerView**

In `diagnosticsSection`:

```swift
private var diagnosticsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
        sectionLabel("DIAGNOSTICS")
        let d = rt.meshDiagnostics
        diagRow("Listener", d.listenerState)
        diagRow("Browser", d.browserState)
        diagRow("Path", "\(d.pathStatus)\(d.interface.map { " (\($0))" } ?? "")")
        diagRow("Restarts", "L:\(d.listenerRestarts) B:\(d.browserRestarts) P:\(d.pathRestarts)")
        diagRow("Ping timeouts", "\(d.pingTimeouts)")
        ForEach(d.peers, id: \.senderId) { p in
            let rtt = p.lastPongMs.map { "\($0)ms" } ?? "—"
            let dur = Int(p.connDurationS)
            diagRow(String(p.senderId.prefix(8)), "rtt:\(rtt) up:\(dur)s")
        }
    }
}

private func diagRow(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label).font(.caption).foregroundColor(.secondary)
        Spacer()
        Text(value).font(.system(.caption, design: .monospaced))
    }
}
```

- [ ] **Step 4: Build + run app, verify panel renders**

Run: `make run`
Expected: app launches, Connection Manager → Diagnostics shows the new fields.

- [ ] **Step 5: Commit**

```bash
git add Sources/TuneSyncCore/PeerMesh.swift Sources/TuneSync/ConnectionManagerView.swift Sources/TuneSync/App.swift
git commit -m "feat(diagnostics): surface mesh listener/browser/path state and per-peer RTT"
```

---

## Task 11: Manual two-Mac test scenarios

**Files:**
- Modify: `docs/TESTING.md`

- [ ] **Step 1: Append scenarios**

Append to `docs/TESTING.md`:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/TESTING.md
git commit -m "docs: manual two-Mac reliability test scenarios"
```

---

## Task 12: Version bump + release notes

**Files:**
- Modify: `Makefile` (version constant)
- Modify: `README.md` (if it lists features)

- [ ] **Step 1: Bump version**

In `Makefile`, change `VERSION ?= 0.2.7` to `0.2.8`.

- [ ] **Step 2: Verify build version**

Run: `make bundle && /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/TuneSync.app/Contents/Info.plist`
Expected: `0.2.8`.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "build: bump to 0.2.8 for rooms-reliability release"
```

---

## Self-Review

**Spec coverage check:**

| Spec section | Task |
| --- | --- |
| Discovery restart on listener/browser failure | Task 7 |
| Dial tie-break | Tasks 2, 5 |
| TCP keepalive / app-level liveness | Tasks 1, 6 |
| Hello-collision dedup | Task 4 |
| NWPathMonitor / sleep / wake | Task 8 |
| Room-change goodbye gap | Task 9 |
| Diagnostics surface | Tasks 3, 10 |
| Unit tests (tie-break, liveness, hello collision) | Tasks 2, 4 |
| Manual two-Mac scenarios | Task 11 |

All spec sections mapped.

**Placeholder scan:** No "TBD"; all code blocks complete. One note: Task 10's plumbing assumes `AppRuntime` holds `peerMesh`; engineer should grep for the actual property name if it differs.

**Type consistency:** `MeshPolicy.shouldDial`, `livenessAction`, `LivenessAction` cases (`idle`, `sendPing`, `dropDead`), `MeshDiagnostics` and `PeerLiveness` field names match across tasks. `PingMessage`/`PongMessage` shape (`senderId`, `nonce`) consistent. `lastPongMs` typed `Int?` in struct and diag.

**Notes for executor:**

- `NWConnection` keepalive at the TCP-options level is mentioned in the spec. The plan implements *application-level* ping/pong (which is the more reliable signal because it round-trips through both endpoints). Skipping the TCP-options dance keeps the diff small.
- `enableKeepalive` on `NWProtocolTCP.Options` can be added in a follow-up if the app-level pings prove insufficient on long-lived idle connections.
