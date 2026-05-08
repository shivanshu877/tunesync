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
