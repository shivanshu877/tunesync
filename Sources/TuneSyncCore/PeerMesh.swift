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
    }

    public func stop() {
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
            room = next
            // Drop all peers + restart with new room
            for (_, p) in peers { p.connection.cancel() }
            peers.removeAll()
            for (_, c) in pendingByEndpoint { c.cancel() }
            pendingByEndpoint.removeAll()
            pendingParsers.removeAll()
            discovered.removeAll()
            kicked.removeAll()
            listener?.cancel()
            browser?.cancel()
            startListener()
            startBrowser()
            notifyChange()
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
            listener.stateUpdateHandler = { state in
                Log.mesh.info("listener state \(String(describing: state), privacy: .public)")
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
        browser.stateUpdateHandler = { state in
            Log.mesh.info("browser state \(String(describing: state), privacy: .public)")
        }
        browser.start(queue: queue)
        self.browser = browser
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

            let conn = NWConnection(to: result.endpoint, using: .tcp)
            pendingByEndpoint[result.endpoint] = conn
            pendingParsers[result.endpoint] = FrameParser()
            configureConnection(conn, side: .outgoing)
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
        } else {
            pendingParsers[endpoint] = parser
        }

        for frame in frames {
            guard let msg = try? JSONDecoder().decode(SyncMessage.self, from: frame) else { continue }
            switch msg {
            case .hello(let h):
                // Update existing peer's host claim if we already know them
                if peers[h.senderId] != nil {
                    let newHost = h.host ?? false
                    if peers[h.senderId]!.isHost != newHost {
                        peers[h.senderId]!.isHost = newHost
                        notifyChange()
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
            }
        }
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
