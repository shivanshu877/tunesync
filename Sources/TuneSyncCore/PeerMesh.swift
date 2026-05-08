import AppKit
import Foundation
import Network

public struct ConnectedPeer: Equatable, Sendable {
    public let senderId: String
    public let displayName: String
    public let connectedAt: Date
    /// True if this peer's most recent hello/state announced host=true.
    public let isHost: Bool

    public init(senderId: String, displayName: String, connectedAt: Date, isHost: Bool = false) {
        self.senderId = senderId
        self.displayName = displayName
        self.connectedAt = connectedAt
        self.isHost = isHost
    }
}

public struct DiscoveredPeer: Equatable, Sendable {
    public let senderId: String
    public let displayName: String
    public let room: String
}

public protocol PeerMeshDelegate: AnyObject {
    func peerMesh(_ mesh: PeerMesh, received message: SyncMessage, from peerId: String)
    func peerMesh(_ mesh: PeerMesh, peersChanged connected: [ConnectedPeer], discovered: [DiscoveredPeer], room: String)
}

public final class PeerMesh: @unchecked Sendable {

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

    private struct Discovered: Equatable {
        let senderId: String
        let displayName: String
        let room: String
        let endpoint: NWEndpoint
    }

    public weak var delegate: PeerMeshDelegate?

    public let senderId: String
    public let displayName: String

    /// True if this Mac currently claims host. Set by the app when the
    /// user toggles role; sent in every outgoing hello and stamped on
    /// every state message via SyncEngine.
    public var isHostClaim: Bool = false

    private let serviceType: String
    private let queue = DispatchQueue(label: "com.tunesync.mesh")

    private var listener: NWListener?
    private var browser: NWBrowser?

    private var peers: [String: PeerConn] = [:]
    private var pendingByEndpoint: [NWEndpoint: NWConnection] = [:]
    private var pendingParsers: [NWEndpoint: FrameParser] = [:]
    private var discovered: [String: Discovered] = [:]
    private var kicked: Set<String> = []

    private var room: String

    private var livenessTimer: DispatchSourceTimer?
    private var pingTimeoutCount: Int = 0
    private var nonceCounter: Int64 = 0

    private var listenerRestartAttempt: Int = 0
    private var browserRestartAttempt: Int = 0
    private var listenerRestartCount: Int = 0
    private var browserRestartCount: Int = 0
    private var lastListenerState: String = "—"
    private var lastBrowserState: String = "—"
    private var stopping: Bool = false

    private var pathMonitor: NWPathMonitor?
    private var lastPath: NWPath?
    private var pathRestartCount: Int = 0
    private var lastPathStatus: String = "—"
    private var lastPathInterface: String? = nil
    private var unsatisfiedSince: Date? = nil
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    public init(
        senderId: String,
        displayName: String,
        room: String = "default",
        serviceType: String = "_tunesync._tcp"
    ) {
        self.senderId = senderId
        self.displayName = displayName
        self.room = room
        self.serviceType = serviceType
    }

    public func start() {
        startListener()
        startBrowser()
        startLivenessLoop()
        startPathMonitor()
        startWakeSleepObservers()
    }

    public func stop() {
        stopping = true
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

    public func broadcast(_ message: SyncMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let frame = FrameCodec.encode(data)
        queue.async { [self] in
            for (_, p) in peers {
                p.connection.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }

    public var peerCount: Int { peers.count }

    public var currentRoom: String {
        get { queue.sync { room } }
    }

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
            stopping = true
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
                self.stopping = false
                self.startListener()
                self.startBrowser()
                self.notifyChange()
            }
        }
    }

    public func kick(senderId: String) {
        queue.async { [self] in
            guard let pc = peers[senderId] else { return }
            kicked.insert(senderId)
            pc.connection.cancel()
            peers.removeValue(forKey: senderId)
            Log.mesh.info("kicked peer: \(senderId, privacy: .public)")
            notifyChange()
        }
    }

    public func reconnect(senderId: String) {
        queue.async { [self] in
            kicked.remove(senderId)
            guard let d = discovered[senderId] else { return }
            if peers[senderId] != nil { return }
            if pendingByEndpoint[d.endpoint] != nil { return }
            let conn = NWConnection(to: d.endpoint, using: .tcp)
            pendingByEndpoint[d.endpoint] = conn
            pendingParsers[d.endpoint] = FrameParser()
            configureConnection(conn, side: .outgoing)
        }
    }

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            let txt = NWTXTRecord([
                "id": senderId,
                "name": displayName,
                "room": room,
            ])
            listener.service = NWListener.Service(
                name: "TuneSync-\(senderId.prefix(8))",
                type: serviceType,
                domain: nil,
                txtRecord: txt
            )
            listener.newConnectionHandler = { [weak self] conn in
                self?.acceptIncoming(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    self.lastListenerState = String(describing: state)
                    Log.mesh.info("listener state \(String(describing: state), privacy: .public)")
                    switch state {
                    case .ready:
                        self.listenerRestartAttempt = 0
                    case .failed:
                        self.scheduleListenerRestart()
                    case .cancelled:
                        if !self.stopping { self.scheduleListenerRestart() }
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Log.mesh.error("listener start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func acceptIncoming(_ conn: NWConnection) {
        let endpoint = conn.endpoint
        pendingByEndpoint[endpoint] = conn
        pendingParsers[endpoint] = FrameParser()
        configureConnection(conn, side: .incoming)
    }

    private func startBrowser() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
            using: params
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowse(results)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.lastBrowserState = String(describing: state)
                Log.mesh.info("browser state \(String(describing: state), privacy: .public)")
                switch state {
                case .ready:
                    self.browserRestartAttempt = 0
                case .failed:
                    self.scheduleBrowserRestart()
                case .cancelled:
                    if !self.stopping { self.scheduleBrowserRestart() }
                default:
                    break
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

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

    private func handleBrowse(_ results: Set<NWBrowser.Result>) {
        var newDiscovered: [String: Discovered] = [:]

        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                  let id = txt.dictionary["id"],
                  id != senderId else { continue }
            let name = txt.dictionary["name"] ?? "Mac"
            let resultRoom = txt.dictionary["room"] ?? "default"
            if resultRoom != room { continue }

            newDiscovered[id] = Discovered(senderId: id, displayName: name, room: resultRoom, endpoint: result.endpoint)

            // Auto-connect unless kicked or already pending/connected
            if peers[id] != nil { continue }
            if kicked.contains(id) { continue }
            if pendingByEndpoint[result.endpoint] != nil { continue }

            if MeshPolicy.shouldDial(localId: senderId, remoteId: id) {
                let conn = NWConnection(to: result.endpoint, using: .tcp)
                pendingByEndpoint[result.endpoint] = conn
                pendingParsers[result.endpoint] = FrameParser()
                configureConnection(conn, side: .outgoing)
            } else {
                // Fallback dial: if we're the higher-id peer and the lower-id peer
                // never connects within 5s (asymmetric reachability), dial anyway.
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
        }

        if newDiscovered != discovered {
            discovered = newDiscovered
            notifyChange()
        }
    }

    private enum Side { case incoming, outgoing }

    private func configureConnection(_ conn: NWConnection, side: Side) {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if side == .outgoing {
                    self.sendHello(on: conn)
                }
                self.startReceiveLoop(on: conn)
            case .failed, .cancelled:
                self.removePending(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendHello(on conn: NWConnection) {
        let hello = SyncMessage.hello(HelloMessage(
            senderId: senderId, displayName: displayName, host: isHostClaim
        ))
        guard let data = try? JSONEncoder().encode(hello) else { return }
        let frame = FrameCodec.encode(data)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func startReceiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleIncomingBytes(data, on: conn)
            }
            if isComplete || error != nil {
                self.cleanup(conn)
                return
            }
            self.startReceiveLoop(on: conn)
        }
    }

    private func handleIncomingBytes(_ bytes: Data, on conn: NWConnection) {
        let endpoint = conn.endpoint
        var parser: FrameParser
        var existingPeerId: String? = nil

        if let id = peerId(forEndpoint: endpoint) {
            parser = peers[id]!.parser
            existingPeerId = id
        } else if pendingParsers[endpoint] != nil {
            parser = pendingParsers[endpoint]!
        } else {
            return
        }

        parser.append(bytes)
        let frames = parser.drain()

        if let id = existingPeerId {
            peers[id]?.parser = parser
            peers[id]?.lastSeen = Date()
        } else {
            pendingParsers[endpoint] = parser
        }

        for frame in frames {
            guard let msg = try? JSONDecoder().decode(SyncMessage.self, from: frame) else { continue }
            switch msg {
            case .hello(let h):
                // Update existing peer's host claim if we already know them
                if let existing = peers[h.senderId] {
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
                    if kicked.contains(h.senderId) {
                        conn.cancel()
                        continue
                    }
                    var pc = PeerConn(
                        id: h.senderId,
                        displayName: h.displayName,
                        connection: conn,
                        connectedAt: Date(),
                        parser: parser
                    )
                    pc.isHost = h.host ?? false
                    peers[h.senderId] = pc
                    pendingByEndpoint.removeValue(forKey: endpoint)
                    pendingParsers.removeValue(forKey: endpoint)
                    Log.mesh.info("peer connected: \(h.senderId, privacy: .public) (\(h.displayName, privacy: .public)) host=\(pc.isHost, privacy: .public)")
                    sendHello(on: conn)
                    notifyChange()
                }
            case .state(let s):
                // Track host claims that arrive via state messages, not just hello
                if let pid = existingPeerId ?? peerId(forEndpoint: endpoint),
                   let claimed = s.host,
                   peers[pid]?.isHost != claimed {
                    peers[pid]?.isHost = claimed
                    notifyChange()
                }
                if let id = existingPeerId ?? peerId(forEndpoint: endpoint) {
                    delegate?.peerMesh(self, received: msg, from: id)
                }
            case .bye:
                if let id = existingPeerId ?? peerId(forEndpoint: endpoint) {
                    delegate?.peerMesh(self, received: msg, from: id)
                    removePeer(id: id)
                }
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
            }
        }
    }

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

    private func peerId(forEndpoint endpoint: NWEndpoint) -> String? {
        for (id, p) in peers where p.connection.endpoint == endpoint { return id }
        return nil
    }

    private func cleanup(_ conn: NWConnection) {
        let endpoint = conn.endpoint
        pendingByEndpoint.removeValue(forKey: endpoint)
        pendingParsers.removeValue(forKey: endpoint)
        if let id = peerId(forEndpoint: endpoint) {
            removePeer(id: id)
        }
        conn.cancel()
    }

    private func removePending(_ conn: NWConnection) {
        pendingByEndpoint.removeValue(forKey: conn.endpoint)
        pendingParsers.removeValue(forKey: conn.endpoint)
    }

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

    private func removePeer(id: String) {
        peers.removeValue(forKey: id)
        Log.mesh.info("peer removed: \(id, privacy: .public)")
        notifyChange()
    }

    private func notifyChange() {
        let connected: [ConnectedPeer] = peers.values
            .map { ConnectedPeer(senderId: $0.id, displayName: $0.displayName, connectedAt: $0.connectedAt, isHost: $0.isHost) }
            .sorted { $0.connectedAt < $1.connectedAt }

        let connectedIds = Set(connected.map { $0.senderId })
        let disc: [DiscoveredPeer] = discovered.values
            .filter { !connectedIds.contains($0.senderId) }
            .map { DiscoveredPeer(senderId: $0.senderId, displayName: $0.displayName, room: $0.room) }
            .sorted { $0.displayName < $1.displayName }

        let snap = (connected, disc, room)
        delegate?.peerMesh(self, peersChanged: snap.0, discovered: snap.1, room: snap.2)
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
            if let last = lastPath, last.availableInterfaces != path.availableInterfaces {
                fullMeshRestart(reason: "interface-changed")
            }
        case .unsatisfied:
            if unsatisfiedSince == nil {
                unsatisfiedSince = Date()
            }
        default:
            break
        }
        lastPath = path
    }

    private func fullMeshRestart(reason: String) {
        pathRestartCount += 1
        Log.mesh.info("full mesh restart (\(reason, privacy: .public))")
        stopping = true
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
            self.stopping = false
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
            guard let self else { return }
            self.queue.async {
                let bye = SyncMessage.bye(ByeMessage(senderId: self.senderId))
                if let data = try? JSONEncoder().encode(bye) {
                    let frame = FrameCodec.encode(data)
                    for (_, p) in self.peers {
                        p.connection.send(content: frame, completion: .contentProcessed { _ in })
                    }
                }
            }
        }
    }

    /// Re-broadcasts hello to every connected peer. Call after toggling
    /// isHostClaim so peers learn the new role immediately rather than
    /// waiting for the next state heartbeat.
    public func reannounce() {
        queue.async { [self] in
            for (_, p) in peers {
                sendHello(on: p.connection)
            }
        }
    }
}
