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
    @Published public var meshDiagnostics: MeshDiagnostics = .empty
    @Published public var bridgedClientCount: Int = 0

    /// Wall-clock (ms since epoch) when the next scheduled play will
    /// fire. Nil when nothing is scheduled (the steady state).
    @Published public var scheduledAtMs: Int64?
    /// How late this Mac received the scheduled message — only meaningful
    /// when scheduledAtMs is set. Helps the user understand whether their
    /// network is the slow link in the room.
    @Published public var networkDelayMs: Int64 = 0

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

    private var meshBridge: MeshBridge?
    private let webBridgeBox = WebBridgeBox()
    private var webBridge: Bridge? {
        get { webBridgeBox.bridge }
        set { webBridgeBox.bridge = newValue }
    }
    private var bridgeRelay: BridgeRelay?
    private var diagPollTimer: Timer?

    public init() {
        let id = UUID().uuidString
        let name = Host.current().localizedName ?? "Mac"

        let mesh = PeerMesh(senderId: id, displayName: name, room: "default")
        let webBridgeBox = self.webBridgeBox
        let engine = SyncEngine(
            senderId: id,
            broadcast: { [weak mesh] msg in
                mesh?.broadcast(msg)
                webBridgeBox.bridge?.broadcastToClients(msg)
            },
            applyState: { _, _, _, _ in },
            clockOffsetMsFor: { [weak mesh] sid in
                mesh?.peerOffsetMs(senderId: sid) ?? 0
            }
        )

        self.engine = engine
        self.mesh = mesh

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

        let meshBridge = MeshBridge(owner: self)
        self.meshBridge = meshBridge
        self.mesh.delegate = meshBridge
    }

    public func startDiagPolling() {
        diagPollTimer?.invalidate()
        diagPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let snap = self.mesh.currentDiagnostics()
            DispatchQueue.main.async { self.meshDiagnostics = snap }
        }
    }

    public func start() {
        engine.start()
        mesh.start()
        startDiagPolling()
        updater.startPeriodicChecks()
    }

    public func stop() {
        engine.stop()
        mesh.stop()
        webBridge?.stop()
        webBridge = nil
        updater.stop()
    }

    public func changeRoom(_ name: String) {
        mesh.setRoom(name)
        webBridge?.stop()
        webBridge = nil
        bridgedClientCount = 0
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
        let remoteHost = connectedPeers.first(where: { $0.isHost })
        role = (remoteHost != nil) ? .guest : .unset
        engine.role = role
        mesh.isHostClaim = false
        mesh.reannounce()
    }

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
            DispatchQueue.main.async {
                self.lastWriter = String(s.senderId.prefix(8))
                if let cms = s.clientMs, s.startAtMs != nil {
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    self.networkDelayMs = max(0, nowMs - cms)
                }
            }
        }
        engine.handleRemote(message)
        webBridge?.broadcastToClients(message)
    }

    fileprivate func handleWebClientMessage(_ message: SyncMessage, fromClient id: String) {
        engine.handleRemote(message)
        mesh.broadcast(message)
    }

    fileprivate func peersChanged(_ connected: [ConnectedPeer], _ discovered: [DiscoveredPeer], room: String) {
        DispatchQueue.main.async {
            self.connectedPeers = connected
            self.discoveredPeers = discovered
            self.currentRoom = room
            self.reconcileRole()
            self.reconcileBridge()
        }
    }

    private func reconcileBridge() {
        let peerIds = connectedPeers.map { $0.senderId }
        let shouldRun = BridgeElection.shouldBridge(localId: senderId, peerIds: peerIds)
        if shouldRun && webBridge == nil {
            let b = Bridge(port: 8732, room: currentRoom)
            if bridgeRelay == nil { bridgeRelay = BridgeRelay(owner: self) }
            b.delegate = bridgeRelay
            do {
                try b.start()
                webBridge = b
                Log.player.info("web bridge started on :8732")
            } catch {
                Log.player.error("web bridge start failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if !shouldRun && webBridge != nil {
            webBridge?.stop()
            webBridge = nil
            bridgedClientCount = 0
            Log.player.info("web bridge stopped (lost election)")
        }
    }
}

final class WebBridgeBox: @unchecked Sendable {
    var bridge: Bridge?
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

public struct ContentView: View {
    @ObservedObject var rt: AppRuntime
    @State private var showSidebar: Bool = false
    @State private var searchQuery: String = ""
    @State private var showImportSheet: Bool = false

    public init(rt: AppRuntime) {
        self.rt = rt
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                Divider()
                ZStack {
                    WebViewHost(player: rt.player)
                        .frame(minWidth: 800, minHeight: 600)
                    CountdownOverlay(rt: rt)
                        .allowsHitTesting(false)
                }
                StatusBar(
                    peerCount: .init(get: { rt.peerCount }, set: { _ in }),
                    lastWriter: .init(get: { rt.lastWriter }, set: { _ in }),
                    adShowing: .init(get: { rt.adShowing }, set: { _ in }),
                    room: .init(get: { rt.currentRoom }, set: { _ in }),
                    bridgedClients: .init(get: { rt.bridgedClientCount }, set: { _ in })
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
                Button { showImportSheet = true } label: {
                    Label("Import session", systemImage: "key.fill")
                }
                .help("Import a YouTube Music session from another browser")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } }) {
                    Label(showSidebar ? "Hide Peers" : "Show Peers",
                          systemImage: showSidebar ? "sidebar.right" : "person.2")
                }
                .help(showSidebar ? "Hide Connection Manager" : "Show Connection Manager")
            }
        }
        .sheet(isPresented: $showImportSheet) {
            CookieImportSheet(rt: rt)
        }
        .onAppear { rt.start() }
        .onDisappear { rt.stop() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search YouTube Music…", text: $searchQuery, onCommit: submitSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func submitSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        if let url = URL(string: "https://music.youtube.com/search?q=\(encoded)") {
            rt.player.navigate(to: url)
        }
    }
}
