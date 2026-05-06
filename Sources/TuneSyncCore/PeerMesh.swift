import Foundation
import Network

public protocol PeerMeshDelegate: AnyObject {
    func peerMesh(_ mesh: PeerMesh, received message: SyncMessage, from peerId: String)
    func peerMesh(_ mesh: PeerMesh, peerCountChanged count: Int)
}

public final class PeerMesh: @unchecked Sendable {

    private struct PeerConn {
        let id: String
        var displayName: String
        let connection: NWConnection
        var parser = FrameParser()
    }

    public weak var delegate: PeerMeshDelegate?

    public let senderId: String
    public let displayName: String

    private let serviceType: String
    private let queue = DispatchQueue(label: "com.tunesync.mesh")

    private var listener: NWListener?
    private var browser: NWBrowser?

    private var peers: [String: PeerConn] = [:]
    private var pendingByEndpoint: [NWEndpoint: NWConnection] = [:]
    private var pendingParsers: [NWEndpoint: FrameParser] = [:]

    public init(
        senderId: String,
        displayName: String,
        serviceType: String = "_tunesync._tcp"
    ) {
        self.senderId = senderId
        self.displayName = displayName
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

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            let txt = NWTXTRecord([
                "id": senderId,
                "name": displayName,
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
        for result in results {
            if case .bonjour(let txt) = result.metadata,
               txt.dictionary["id"] == senderId {
                continue
            }
            if pendingByEndpoint[result.endpoint] != nil { continue }
            if peersAlreadyConnected(to: result) { continue }

            let conn = NWConnection(to: result.endpoint, using: .tcp)
            pendingByEndpoint[result.endpoint] = conn
            pendingParsers[result.endpoint] = FrameParser()
            configureConnection(conn, side: .outgoing)
        }
    }

    private func peersAlreadyConnected(to result: NWBrowser.Result) -> Bool {
        guard case .bonjour(let txt) = result.metadata, let id = txt.dictionary["id"] else {
            return false
        }
        return peers[id] != nil
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
        let hello = SyncMessage.hello(HelloMessage(senderId: senderId, displayName: displayName))
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
                if peers[h.senderId] == nil, h.senderId != senderId {
                    let activeParser = peers[h.senderId]?.parser ?? parser
                    let pc = PeerConn(id: h.senderId, displayName: h.displayName, connection: conn, parser: activeParser)
                    peers[h.senderId] = pc
                    pendingByEndpoint.removeValue(forKey: endpoint)
                    pendingParsers.removeValue(forKey: endpoint)
                    Log.mesh.info("peer connected: \(h.senderId, privacy: .public) (\(h.displayName, privacy: .public))")
                    delegate?.peerMesh(self, peerCountChanged: peers.count)
                    sendHello(on: conn)
                }
            case .state, .bye:
                if let id = existingPeerId ?? peerId(forEndpoint: endpoint) {
                    delegate?.peerMesh(self, received: msg, from: id)
                }
                if case .bye = msg, let id = existingPeerId ?? peerId(forEndpoint: endpoint) {
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
        delegate?.peerMesh(self, peerCountChanged: peers.count)
        Log.mesh.info("peer removed: \(id, privacy: .public)")
    }
}
