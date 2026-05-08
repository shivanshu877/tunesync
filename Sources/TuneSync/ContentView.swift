import SwiftUI
import TuneSyncCore

@MainActor
public final class AppRuntime: ObservableObject {
    @Published public var connectedPeers: [ConnectedPeer] = []
    @Published public var discoveredPeers: [DiscoveredPeer] = []
    @Published public var currentRoom: String = "default"
    @Published public var lastWriter: String?
    @Published public var adShowing: Bool = false

    @Published public var lastDiag: DiagSnapshot?
    @Published public var lastLocalState: PlayerState?
    @Published public var syncHistory: [SyncEntry] = []
    @Published public var role: Role = .unset

    public var peerCount: Int { connectedPeers.count }
    public var senderId: String { engine.senderId }
    public var hostDisplayName: String? {
        if role == .host { return Host.current().localizedName ?? "This Mac" }
        return connectedPeers.first(where: { $0.isHost })?.displayName
    }

    public let player = PlayerController()
    public let engine: SyncEngine
    public let mesh: PeerMesh
    public let updater = Updater()

    private var bridge: MeshBridge?

    public init() {
        let id = UUID().uuidString
        let name = Host.current().localizedName ?? "Mac"

        let mesh = PeerMesh(senderId: id, displayName: name, room: "default")
        let engine = SyncEngine(
            senderId: id,
            broadcast: { [weak mesh] msg in mesh?.broadcast(msg) },
            applyState: { _ in }
        )

        self.engine = engine
        self.mesh = mesh

        self.engine.applyStateOverride { [weak self] state in
            DispatchQueue.main.async { self?.player.applyState(state) }
        }

        self.player.onLocalState = { [weak self] state in
            DispatchQueue.main.async { self?.lastLocalState = state }
            self?.engine.localStateChanged(state)
        }
        self.player.onAdStateChanged = { [weak self] ad in
            DispatchQueue.main.async { self?.adShowing = ad }
            self?.engine.adShowing = ad
        }
        self.player.onDiag = { [weak self] diag in
            DispatchQueue.main.async { self?.lastDiag = diag }
        }
        self.engine.onHistoryChanged = { [weak self] in
            guard let self else { return }
            let snap = self.engine.history
            DispatchQueue.main.async { self.syncHistory = snap }
        }

        let bridge = MeshBridge(owner: self)
        self.bridge = bridge
        self.mesh.delegate = bridge
    }

    public func start() {
        engine.start()
        mesh.start()
        updater.startPeriodicChecks()
    }

    public func stop() {
        engine.stop()
        mesh.stop()
        updater.stop()
    }

    public func changeRoom(_ name: String) {
        mesh.setRoom(name)
    }

    public func kickPeer(_ senderId: String) {
        mesh.kick(senderId: senderId)
    }

    public func reconnectPeer(_ senderId: String) {
        mesh.reconnect(senderId: senderId)
    }

    public func becomeHost() {
        role = .host
        engine.role = .host
        mesh.isHostClaim = true
        mesh.reannounce()
    }

    public func stepDown() {
        // If a remote peer is currently host, demote ourselves to guest;
        // otherwise revert to unset (no host in the room).
        let remoteHost = connectedPeers.first(where: { $0.isHost })
        role = (remoteHost != nil) ? .guest : .unset
        engine.role = role
        mesh.isHostClaim = false
        mesh.reannounce()
    }

    /// Auto-demote ourselves to guest if a remote peer claims host while
    /// we don't (or if a remote peer with a smaller senderId also claims
    /// host alongside us — tiebreak prevents both from heartbeating).
    fileprivate func reconcileRole() {
        let remoteHosts = connectedPeers.filter { $0.isHost }
        let remoteHost = remoteHosts.first
        switch role {
        case .unset:
            if remoteHost != nil {
                role = .guest
                engine.role = .guest
            }
        case .guest:
            if remoteHost == nil {
                role = .unset
                engine.role = .unset
            }
        case .host:
            // Conflict: another peer also claims host. Lower senderId wins.
            if let other = remoteHosts.first(where: { $0.senderId < senderId }) {
                Log.player.info("yielding host to \(other.senderId, privacy: .public) (lower senderId)")
                role = .guest
                engine.role = .guest
                mesh.isHostClaim = false
                mesh.reannounce()
            }
        }
    }

    fileprivate func received(_ message: SyncMessage, from peerId: String) {
        if case .state(let s) = message {
            DispatchQueue.main.async { self.lastWriter = String(s.senderId.prefix(8)) }
        }
        engine.handleRemote(message)
    }

    fileprivate func peersChanged(_ connected: [ConnectedPeer], _ discovered: [DiscoveredPeer], room: String) {
        DispatchQueue.main.async {
            self.connectedPeers = connected
            self.discoveredPeers = discovered
            self.currentRoom = room
            self.reconcileRole()
        }
    }
}

final class MeshBridge: PeerMeshDelegate, @unchecked Sendable {
    weak var owner: AppRuntime?
    init(owner: AppRuntime) { self.owner = owner }

    func peerMesh(_ mesh: PeerMesh, received message: SyncMessage, from peerId: String) {
        let ownerRef = owner
        Task { @MainActor in ownerRef?.received(message, from: peerId) }
    }

    func peerMesh(_ mesh: PeerMesh, peersChanged connected: [ConnectedPeer], discovered: [DiscoveredPeer], room: String) {
        let ownerRef = owner
        Task { @MainActor in ownerRef?.peersChanged(connected, discovered, room: room) }
    }
}

public struct ContentView: View {
    @ObservedObject var rt: AppRuntime
    @State private var showSidebar: Bool = false

    public init(rt: AppRuntime) {
        self.rt = rt
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                WebViewHost(player: rt.player)
                    .frame(minWidth: 800, minHeight: 600)
                StatusBar(
                    peerCount: .init(get: { rt.peerCount }, set: { _ in }),
                    lastWriter: .init(get: { rt.lastWriter }, set: { _ in }),
                    adShowing: .init(get: { rt.adShowing }, set: { _ in }),
                    room: .init(get: { rt.currentRoom }, set: { _ in })
                )
            }
            if showSidebar {
                Divider()
                ConnectionManagerView(rt: rt)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } }) {
                    Label(showSidebar ? "Hide Peers" : "Show Peers",
                          systemImage: showSidebar ? "sidebar.right" : "person.2")
                }
                .help(showSidebar ? "Hide Connection Manager" : "Show Connection Manager")
            }
        }
        .onAppear { rt.start() }
        .onDisappear { rt.stop() }
    }
}
