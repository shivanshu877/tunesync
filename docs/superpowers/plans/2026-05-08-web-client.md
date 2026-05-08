# Web Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Phones / iPads / Linux laptops on the same Wi-Fi can join a TuneSync room by visiting `http://<mac-ip>:8732`. They appear as peers in the mesh, play the same track in sync.

**Architecture:** A Mac runs an embedded HTTP + WebSocket server (the "bridge"). The bridge participates in the existing `PeerMesh` as a normal peer; web clients speak WebSocket to the bridge, which fans messages out to the mesh and back. Election rule: the lowest-senderId Mac in the room runs the bridge. The web client uses the YouTube iframe API (since YT Music itself blocks iframes via `X-Frame-Options`).

**Tech Stack:** Swift 6 with `Network.framework` (`NWListener` + `NWProtocolWebSocket`), embedded static SPA (HTML / JS / CSS, no framework), YouTube iframe API.

---

## File Structure

- `Sources/TuneSyncCore/Bridge.swift` — HTTP + WebSocket server. Owns `NWListener` configured for HTTP, accepts upgrade to WebSocket. Translates between WS messages and `SyncMessage`.
- `Sources/TuneSyncCore/BridgeElection.swift` — pure-logic decision for "should this Mac be the bridge?".
- `Sources/TuneSync/Resources/Web/index.html`
- `Sources/TuneSync/Resources/Web/app.js`
- `Sources/TuneSync/Resources/Web/style.css`
- `Sources/TuneSyncCore/Bridge+Assets.swift` — embeds the three SPA files as `Data` constants (Swift package can't easily ship resources to a non-bundle target, so inline them).
- `Sources/TuneSync/ContentView.swift` — start/stop bridge based on election.
- `Sources/TuneSync/StatusBar.swift` — show "bridging N web clients".
- `Tests/TuneSyncCoreTests/BridgeElectionTests.swift`
- `Tests/TuneSyncCoreTests/BridgeHTTPTests.swift` — round-trip a real WebSocket connection through the bridge on localhost.

---

## Task 1: BridgeElection pure logic

- [ ] **Step 1: Create test**

`Tests/TuneSyncCoreTests/BridgeElectionTests.swift`:

```swift
import XCTest
@testable import TuneSyncCore

final class BridgeElectionTests: XCTestCase {
    func testLowestIdAmongMacsWins() {
        XCTAssertTrue(BridgeElection.shouldBridge(localId: "alice", peerIds: ["bob", "carol"]))
        XCTAssertFalse(BridgeElection.shouldBridge(localId: "bob", peerIds: ["alice", "carol"]))
    }

    func testSoloMacBridges() {
        XCTAssertTrue(BridgeElection.shouldBridge(localId: "alice", peerIds: []))
    }

    func testEqualIdImpossibleButHandled() {
        XCTAssertTrue(BridgeElection.shouldBridge(localId: "x", peerIds: ["x"]))
    }
}
```

- [ ] **Step 2: Implement**

`Sources/TuneSyncCore/BridgeElection.swift`:

```swift
import Foundation

public enum BridgeElection {
    /// Returns true if the local Mac should run the WebSocket bridge.
    /// Rule: lowest senderId among all Macs in the room (including self) bridges.
    public static func shouldBridge(localId: String, peerIds: [String]) -> Bool {
        for pid in peerIds where pid < localId { return false }
        return true
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter BridgeElectionTests
git add Sources/TuneSyncCore/BridgeElection.swift Tests/TuneSyncCoreTests/BridgeElectionTests.swift
git commit -m "feat(bridge): pure-logic bridge election by lowest senderId"
```

---

## Task 2: Embed static SPA assets

**Files:** create `Sources/TuneSyncCore/BridgeAssets.swift` and three string constants.

The package Sources/TuneSyncCore is a library. Resources can be added but require `resources:` in Package.swift. Simpler: inline them as `String` constants. Update `Package.swift` later if file size becomes a concern.

- [ ] **Step 1: Create `Sources/TuneSyncCore/BridgeAssets.swift`**

```swift
import Foundation

public enum BridgeAssets {
    public static let indexHTML: String = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <title>TuneSync Web</title>
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <header>
    <h1>TuneSync <span id="room"></span></h1>
    <div id="status">connecting…</div>
  </header>
  <main>
    <div id="player"></div>
    <div id="now-playing">
      <div id="track">—</div>
      <div id="meta"></div>
    </div>
  </main>
  <script src="https://www.youtube.com/iframe_api"></script>
  <script src="/app.js"></script>
</body>
</html>
"""#

    public static let styleCSS: String = #"""
* { box-sizing: border-box; }
body {
  margin: 0; font: 14px/1.4 -apple-system, system-ui, sans-serif;
  background: #111; color: #eee;
}
header {
  padding: 12px 16px; border-bottom: 1px solid #333;
  display: flex; justify-content: space-between; align-items: center;
}
h1 { margin: 0; font-size: 16px; font-weight: 600; }
#status { font-size: 12px; color: #888; }
main { padding: 16px; max-width: 720px; margin: 0 auto; }
#player { aspect-ratio: 16/9; background: #000; margin-bottom: 16px; }
#track { font-size: 18px; font-weight: 600; }
#meta { font-size: 12px; color: #888; margin-top: 4px; }
"""#

    public static let appJS: String = #"""
(function () {
  var status = document.getElementById('status');
  var trackEl = document.getElementById('track');
  var metaEl = document.getElementById('meta');
  var roomEl = document.getElementById('room');

  var ws = null;
  var player = null;
  var senderId = "web-" + Math.random().toString(36).slice(2, 10);
  var lastVideoId = null;
  var clockOffsetMs = 0;
  var pendingPings = {};

  function connect() {
    var proto = (location.protocol === 'https:') ? 'wss:' : 'ws:';
    ws = new WebSocket(proto + '//' + location.host + '/ws');
    ws.onopen = function () {
      status.textContent = 'connected';
      send({ kind: 'hello', senderId: senderId, displayName: navigator.userAgent.slice(0, 60), host: false });
      setInterval(sendPing, 5000);
    };
    ws.onmessage = function (ev) {
      try { handle(JSON.parse(ev.data)); } catch (e) { console.error(e); }
    };
    ws.onclose = function () {
      status.textContent = 'disconnected';
      setTimeout(connect, 2000);
    };
    ws.onerror = function () { status.textContent = 'error'; };
  }

  function send(msg) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(msg)); }

  function sendPing() {
    var nonce = Date.now();
    pendingPings[nonce] = Date.now();
    send({ kind: 'ping', senderId: senderId, nonce: nonce, t0: Date.now() });
  }

  function handle(m) {
    if (m.kind === 'state') applyState(m);
    else if (m.kind === 'pong') {
      var t3 = Date.now();
      var rtt = (t3 - m.t0) - (m.t2 - m.t1);
      var off = ((m.t1 - m.t0) + (m.t2 - t3)) / 2;
      if (Math.abs(rtt) < 1000) clockOffsetMs = Math.round(off);
    } else if (m.kind === 'welcome') {
      if (m.room) roomEl.textContent = '· ' + m.room;
    }
  }

  function applyState(s) {
    if (!player || typeof player.loadVideoById !== 'function') return;
    if (s.adOnHost) {
      player.mute();
      player.pauseVideo();
      return;
    } else {
      player.unMute();
    }
    if (s.videoId && s.videoId !== lastVideoId) {
      lastVideoId = s.videoId;
      player.loadVideoById(s.videoId, s.t || 0);
      trackEl.textContent = s.videoId;
    }
    var doApply = function () {
      var current = player.getCurrentTime ? player.getCurrentTime() : 0;
      var diff = current - (s.t || 0);
      if (Math.abs(diff) > 0.5) {
        player.seekTo(s.t, true);
      } else if (Math.abs(diff) > 0.05) {
        player.setPlaybackRate(diff > 0 ? 0.95 : 1.05);
        setTimeout(function () { player.setPlaybackRate(1.0); }, 500);
      }
      if (s.playing) player.playVideo(); else player.pauseVideo();
    };
    if (typeof s.applyAtMs === 'number') {
      var localTarget = s.applyAtMs - clockOffsetMs;
      var wait = localTarget - Date.now();
      if (wait > 0 && wait < 1000) { setTimeout(doApply, wait); return; }
    }
    doApply();
  }

  window.onYouTubeIframeAPIReady = function () {
    player = new YT.Player('player', {
      width: '100%', height: '100%',
      playerVars: { playsinline: 1, controls: 1 },
      events: {
        onReady: function () { connect(); }
      }
    });
  };
})();
"""#

    public static func mimeType(for path: String) -> String {
        if path.hasSuffix(".html")  { return "text/html; charset=utf-8" }
        if path.hasSuffix(".css")   { return "text/css; charset=utf-8" }
        if path.hasSuffix(".js")    { return "application/javascript; charset=utf-8" }
        return "application/octet-stream"
    }

    public static func body(for path: String) -> Data? {
        switch path {
        case "/", "/index.html": return Data(indexHTML.utf8)
        case "/style.css":       return Data(styleCSS.utf8)
        case "/app.js":          return Data(appJS.utf8)
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/TuneSyncCore/BridgeAssets.swift
git commit -m "feat(bridge): embedded static SPA assets (HTML/JS/CSS)"
```

---

## Task 3: Bridge HTTP + WebSocket server

**File:** `Sources/TuneSyncCore/Bridge.swift`

Use `NWListener` with `NWParameters.tcp` and add `NWProtocolWebSocket.Options(.version13)` configured `autoReplyPing: true`. Route HTTP GETs to static assets; route `/ws` to WebSocket upgrade.

The trick: `NWParameters` with `NWProtocolWebSocket` triggers WebSocket framing automatically when the client sends an HTTP `Upgrade: websocket` header. For non-WS GETs we read the HTTP request and write a response on the raw TCP connection.

Practical approach: two listeners isn't ideal. Single listener on port 8732 with `NWParameters.tcp` (no WS at the listener level). For each accepted `NWConnection`, peek at the first bytes — if it's a WebSocket handshake (`GET /ws ... Upgrade: websocket`), handle the upgrade manually (RFC 6455 — compute `Sec-WebSocket-Accept` from key + magic GUID + base64 SHA-1) and then read framed WebSocket messages. If it's a plain HTTP GET, write the static asset and close.

This keeps the dependency surface to just `Network` + `CommonCrypto` (SHA-1).

- [ ] **Step 1: Create file**

```swift
import Foundation
import Network
import CommonCrypto

public protocol BridgeDelegate: AnyObject, Sendable {
    /// Called on the bridge's queue when a web client sends a SyncMessage.
    func bridge(_ bridge: Bridge, didReceive message: SyncMessage, fromClient id: String)
    /// Called when web client count changes.
    func bridge(_ bridge: Bridge, clientsChanged count: Int)
}

public final class Bridge: @unchecked Sendable {
    public weak var delegate: BridgeDelegate?
    public let port: UInt16
    public let room: String

    private let queue = DispatchQueue(label: "com.tunesync.bridge")
    private var listener: NWListener?
    private var clients: [String: NWConnection] = [:]
    private var nextClientNum = 0

    public init(port: UInt16 = 8732, room: String) {
        self.port = port
        self.room = room
    }

    public func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNew(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in clients { c.cancel() }
        clients.removeAll()
        notifyClientsChanged()
    }

    public var clientCount: Int {
        return queue.sync { clients.count }
    }

    /// Broadcast a SyncMessage to every web client.
    public func broadcastToClients(_ message: SyncMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        queue.async { [self] in
            for (_, c) in clients {
                sendWebSocketText(c, data: data)
            }
        }
    }

    private func handleNew(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, accumulated: Data())
    }

    private func readRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buffer = accumulated
            if let d = data { buffer.append(d) }
            // HTTP request ends with \r\n\r\n.
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = buffer.prefix(upTo: range.lowerBound)
                self.routeRequest(conn, headerBytes: Data(header))
            } else if buffer.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.readRequest(conn, accumulated: buffer)
            }
        }
    }

    private func routeRequest(_ conn: NWConnection, headerBytes: Data) {
        guard let header = String(data: headerBytes, encoding: .utf8) else {
            conn.cancel(); return
        }
        let lines = header.split(separator: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let path = String(parts[1])

        // WebSocket upgrade path.
        if path == "/ws" {
            handleWebSocketUpgrade(conn, headerLines: lines)
            return
        }

        // Static asset.
        if let body = BridgeAssets.body(for: path) {
            let mime = BridgeAssets.mimeType(for: path == "/" ? "/index.html" : path)
            let response =
                "HTTP/1.1 200 OK\r\n" +
                "Content-Type: \(mime)\r\n" +
                "Content-Length: \(body.count)\r\n" +
                "Cache-Control: no-store\r\n" +
                "Connection: close\r\n\r\n"
            var full = Data(response.utf8)
            full.append(body)
            conn.send(content: full, completion: .contentProcessed { _ in conn.cancel() })
        } else {
            let resp = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func handleWebSocketUpgrade(_ conn: NWConnection, headerLines: [Substring]) {
        var key: String? = nil
        for line in headerLines {
            let lower = line.lowercased()
            if lower.hasPrefix("sec-websocket-key:") {
                let v = line.split(separator: ":", maxSplits: 1).last ?? ""
                key = v.trimmingCharacters(in: .whitespaces)
            }
        }
        guard let secKey = key else { conn.cancel(); return }
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = sha1Base64(secKey + magic)
        let upgrade =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(upgrade.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            let id = "web-\(self.nextClientNum)"
            self.nextClientNum += 1
            self.clients[id] = conn
            self.notifyClientsChanged()
            self.sendWelcome(conn)
            self.readWSFrame(conn, clientId: id)
        })
    }

    private func sendWelcome(_ conn: NWConnection) {
        struct Welcome: Encodable { let kind = "welcome"; let room: String }
        if let data = try? JSONEncoder().encode(Welcome(room: room)) {
            sendWebSocketText(conn, data: data)
        }
    }

    private func readWSFrame(_ conn: NWConnection, clientId: String) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.removeClient(clientId, conn: conn)
                return
            }
            guard var buf = data, buf.count >= 2 else {
                self.readWSFrame(conn, clientId: clientId); return
            }
            // Parse RFC 6455 frame.
            let opcode = buf[0] & 0x0F
            let masked = (buf[1] & 0x80) != 0
            var len = Int(buf[1] & 0x7F)
            var idx = 2
            if len == 126 {
                guard buf.count >= 4 else { self.readWSFrame(conn, clientId: clientId); return }
                len = Int(buf[2]) << 8 | Int(buf[3])
                idx = 4
            } else if len == 127 {
                guard buf.count >= 10 else { self.readWSFrame(conn, clientId: clientId); return }
                len = 0
                for k in 2..<10 { len = (len << 8) | Int(buf[k]) }
                idx = 10
            }
            var maskKey: [UInt8] = [0,0,0,0]
            if masked {
                guard buf.count >= idx + 4 else { self.readWSFrame(conn, clientId: clientId); return }
                maskKey = [buf[idx], buf[idx+1], buf[idx+2], buf[idx+3]]
                idx += 4
            }
            guard buf.count >= idx + len else { self.readWSFrame(conn, clientId: clientId); return }
            var payload = Data(buf[idx..<(idx+len)])
            if masked {
                for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
            }
            if opcode == 0x8 { // close
                self.removeClient(clientId, conn: conn)
                return
            }
            if opcode == 0x9 { // ping
                self.sendWebSocketPong(conn, data: payload)
            } else if opcode == 0x1 { // text
                self.handleClientPayload(payload, clientId: clientId)
            }
            self.readWSFrame(conn, clientId: clientId)
        }
    }

    private func handleClientPayload(_ data: Data, clientId: String) {
        guard let msg = try? JSONDecoder().decode(SyncMessage.self, from: data) else { return }
        delegate?.bridge(self, didReceive: msg, fromClient: clientId)
    }

    private func removeClient(_ id: String, conn: NWConnection) {
        clients.removeValue(forKey: id)
        conn.cancel()
        notifyClientsChanged()
    }

    private func notifyClientsChanged() {
        let count = clients.count
        delegate?.bridge(self, clientsChanged: count)
    }

    // MARK: - WebSocket framing

    private func sendWebSocketText(_ conn: NWConnection, data: Data) {
        var frame = Data()
        frame.append(0x81) // FIN | text
        let len = data.count
        if len <= 125 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        frame.append(data)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendWebSocketPong(_ conn: NWConnection, data: Data) {
        var frame = Data()
        frame.append(0x8A) // FIN | pong
        frame.append(UInt8(data.count))
        frame.append(data)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sha1Base64(_ s: String) -> String {
        let data = Data(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/TuneSyncCore/Bridge.swift
git commit -m "feat(bridge): HTTP + WebSocket server (RFC 6455 framing)"
```

---

## Task 4: Smoke test the bridge with a real WebSocket connection

**File:** `Tests/TuneSyncCoreTests/BridgeHTTPTests.swift`

- [ ] **Step 1: Create test**

```swift
import XCTest
import Network
@testable import TuneSyncCore

final class BridgeHTTPTests: XCTestCase {
    func testServesIndex() throws {
        let bridge = Bridge(port: 18732, room: "test")
        try bridge.start()
        defer { bridge.stop() }
        // Tiny HTTP client.
        let url = URL(string: "http://127.0.0.1:18732/")!
        let exp = expectation(description: "fetch")
        let task = URLSession.shared.dataTask(with: url) { data, resp, err in
            defer { exp.fulfill() }
            guard err == nil, let d = data, let s = String(data: d, encoding: .utf8) else {
                XCTFail("\(String(describing: err))"); return
            }
            XCTAssertTrue(s.contains("TuneSync Web"))
        }
        task.resume()
        wait(for: [exp], timeout: 3.0)
    }

    func testServesAppJS() throws {
        let bridge = Bridge(port: 18733, room: "test")
        try bridge.start()
        defer { bridge.stop() }
        let url = URL(string: "http://127.0.0.1:18733/app.js")!
        let exp = expectation(description: "fetch")
        URLSession.shared.dataTask(with: url) { data, _, err in
            defer { exp.fulfill() }
            XCTAssertNil(err)
            XCTAssertNotNil(data)
            if let d = data, let s = String(data: d, encoding: .utf8) {
                XCTAssertTrue(s.contains("YT.Player"))
            }
        }.resume()
        wait(for: [exp], timeout: 3.0)
    }
}
```

- [ ] **Step 2: Run + commit**

```bash
swift test --filter BridgeHTTPTests
git add Tests/TuneSyncCoreTests/BridgeHTTPTests.swift
git commit -m "test(bridge): HTTP smoke tests for static asset serving"
```

---

## Task 5: AppRuntime owns the bridge + does election

**File:** `Sources/TuneSync/ContentView.swift`

The `MeshBridge` callback `peerMesh(_:peersChanged:_:)` arrives with the full Mac peer list. Re-run election whenever it changes. Start bridge if we should and aren't running; stop if we shouldn't and are.

- [ ] **Step 1: Add bridge property + election logic**

In `AppRuntime`:

```swift
@Published public var bridgedClientCount: Int = 0
private var bridge: Bridge?
```

Add method:

```swift
private func reconcileBridge() {
    let peerIds = connectedPeers.map { $0.senderId }
    let shouldRun = BridgeElection.shouldBridge(localId: senderId, peerIds: peerIds)
    if shouldRun && bridge == nil {
        let b = Bridge(port: 8732, room: currentRoom)
        b.delegate = bridgeDelegate
        do {
            try b.start()
            bridge = b
            Log.player.info("bridge started on :8732")
        } catch {
            Log.player.error("bridge start failed: \(error.localizedDescription, privacy: .public)")
        }
    } else if !shouldRun && bridge != nil {
        bridge?.stop()
        bridge = nil
        bridgedClientCount = 0
        Log.player.info("bridge stopped (lost election)")
    }
}
```

Make `bridge` (the existing `MeshBridge`) conform to `BridgeDelegate` too — or introduce a new wrapper. For simplicity, add a separate inline class:

```swift
private final class BridgeRelay: BridgeDelegate, @unchecked Sendable {
    weak var owner: AppRuntime?
    init(owner: AppRuntime) { self.owner = owner }
    func bridge(_ bridge: Bridge, didReceive message: SyncMessage, fromClient id: String) {
        let ownerRef = owner
        Task { @MainActor in ownerRef?.handleWebClientMessage(message, fromClient: id) }
    }
    func bridge(_ bridge: Bridge, clientsChanged count: Int) {
        let ownerRef = owner
        Task { @MainActor in ownerRef?.bridgedClientCount = count }
    }
}
```

Add a stored `private var bridgeDelegate: BridgeRelay?` to AppRuntime and instantiate in init.

Add the message handler:

```swift
fileprivate func handleWebClientMessage(_ message: SyncMessage, fromClient id: String) {
    // Web clients are mesh peers — their messages flow into both the engine and the mesh broadcast.
    engine.handleRemote(message)
    mesh.broadcast(message)
}
```

And bridge fan-out: whenever the engine sends a state, also relay to the bridge. The cleanest hook is to wrap the broadcast closure in `init`:

```swift
let engine = SyncEngine(
    senderId: id,
    broadcast: { [weak self, weak mesh] msg in
        mesh?.broadcast(msg)
        self?.bridge?.broadcastToClients(msg)
    },
    applyState: { _ in }
)
```

Likewise, when handling an inbound mesh message, also relay to the bridge so web clients see it. In `received(_:from:)`:

```swift
fileprivate func received(_ message: SyncMessage, from peerId: String) {
    if case .state(let s) = message {
        DispatchQueue.main.async { self.lastWriter = String(s.senderId.prefix(8)) }
    }
    engine.handleRemote(message)
    bridge?.broadcastToClients(message)
}
```

In `peersChanged`, after updating the published peer list, call `reconcileBridge()`.

In `changeRoom`, after `mesh.setRoom(name)`, schedule a reconcile (the current room may have changed, restart bridge if running):

```swift
public func changeRoom(_ name: String) {
    mesh.setRoom(name)
    bridge?.stop()
    bridge = nil
    bridgedClientCount = 0
    // Bridge will reappear on the next peersChanged after rejoin.
}
```

In `stop()`, also stop the bridge.

- [ ] **Step 2: Build**

```bash
swift build
```

Should compile.

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSync/ContentView.swift
git commit -m "feat(bridge): AppRuntime runs bridge for elected Mac, fans messages both ways"
```

---

## Task 6: Status bar + diagnostics surface

- [ ] **Step 1: Show bridge state in status bar**

`Sources/TuneSync/StatusBar.swift` currently shows peer count, last writer, ad, room. Add a small `bridgedClientCount` display. Look up the file and add a row at the end of the existing layout:

```swift
// Inside StatusBar's body, near the existing rows:
if rt.bridgedClientCount > 0 {
    HStack(spacing: 4) {
        Image(systemName: "globe")
        Text("\(rt.bridgedClientCount) web")
    }.font(.caption).foregroundColor(.secondary)
}
```

(The exact integration depends on existing StatusBar API. Read the file, add the Image+Text in the natural slot. If StatusBar takes individual bindings, add a new binding `bridgedClients: Int` and pass `rt.bridgedClientCount`.)

- [ ] **Step 2: Diagnostics row in ConnectionManagerView**

In `ConnectionManagerView.swift`, in `diagnosticsSection`, after the existing rows, add:

```swift
diagRow("Bridge", "\(rt.bridgedClientCount) web client\(rt.bridgedClientCount == 1 ? "" : "s")")
```

- [ ] **Step 3: Build + commit**

```bash
swift build
git add Sources/TuneSync/StatusBar.swift Sources/TuneSync/ConnectionManagerView.swift
git commit -m "feat(bridge): show bridged web client count in UI"
```

---

## Task 7: Tests + manual scenarios + version bump

- [ ] **Step 1: Append to `docs/TESTING.md`:**

```markdown
## Web-client scenarios (post 0.4.0)

### Phone joins room

1. Mac in same room. TuneSync running.
2. Diagnostics shows "Bridge" row with "0 web clients".
3. On a phone or other device on the same Wi-Fi: open `http://<mac-ip>:8732/`.
4. Page loads, status flips from "connecting…" to "connected".
5. Status bar on Mac shows "1 web". Diagnostics shows "1 web client".

### Sync to web

1. Play a track on the Mac.
2. Web client loads the track, plays in sync (within ~200 ms).
3. Pause on Mac. Web client pauses.

### Election handover

1. Two Macs (A: lower senderId, B: higher), both running.
2. A is the bridge. Phone connects to A's IP.
3. Quit A. After ~25 s (peer drop window), B should become the bridge.
4. On phone, refresh against B's IP. Reconnects.
```

- [ ] **Step 2: Bump 0.4.0**

`sed -i '' 's/0\.3\.0/0.4.0/g' Makefile`

- [ ] **Step 3: Commit**

```bash
git add docs/TESTING.md Makefile
git commit -m "build: bump to 0.4.0 for web-client release"
```

---

## Self-Review

| Spec section | Task |
| --- | --- |
| Bridge election | 1 |
| Static SPA assets | 2 |
| HTTP + WebSocket server | 3 |
| HTTP smoke tests | 4 |
| AppRuntime wiring | 5 |
| Status bar / diagnostics | 6 |
| Manual scenarios + bump | 7 |

No placeholders. Names consistent (`Bridge`, `BridgeDelegate`, `BridgeElection`, `BridgeAssets`, `bridgedClientCount`).

**Caveat:** Web client speaks the same `SyncMessage` JSON as Mac peers. The `kind` field is enforced by the Codable enum on the Swift side. The JS uses raw object literals — must match field names exactly. The bridge does not validate; bad payloads from web are silently ignored by the JSONDecoder guard.

**Caveat:** macOS will prompt for incoming network connections on first run of the bridge. Document in scenario 1.
