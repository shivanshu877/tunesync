import SwiftUI
import TuneSyncCore

@MainActor
public final class AppRuntime: ObservableObject {
    @Published public var peerCount: Int = 0
    @Published public var lastWriter: String?
    @Published public var adShowing: Bool = false

    public let player = PlayerController()
    public let engine: SyncEngine
    public let mesh: PeerMesh

    private var bridge: MeshBridge?

    public init() {
        let id = UUID().uuidString
        let name = Host.current().localizedName ?? "Mac"

        let mesh = PeerMesh(senderId: id, displayName: name)
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
            self?.engine.localStateChanged(state)
        }
        self.player.onAdStateChanged = { [weak self] ad in
            DispatchQueue.main.async { self?.adShowing = ad }
            self?.engine.adShowing = ad
        }

        let bridge = MeshBridge(owner: self)
        self.bridge = bridge
        self.mesh.delegate = bridge
    }

    public func start() {
        engine.start()
        mesh.start()
    }

    public func stop() {
        engine.stop()
        mesh.stop()
    }

    fileprivate func received(_ message: SyncMessage, from peerId: String) {
        if case .state(let s) = message {
            DispatchQueue.main.async { self.lastWriter = String(s.senderId.prefix(8)) }
        }
        engine.handleRemote(message)
    }

    fileprivate func peersChanged(_ count: Int) {
        DispatchQueue.main.async { self.peerCount = count }
    }
}

final class MeshBridge: PeerMeshDelegate, @unchecked Sendable {
    weak var owner: AppRuntime?
    init(owner: AppRuntime) { self.owner = owner }

    func peerMesh(_ mesh: PeerMesh, received message: SyncMessage, from peerId: String) {
        let ownerRef = owner
        Task { @MainActor in ownerRef?.received(message, from: peerId) }
    }
    func peerMesh(_ mesh: PeerMesh, peerCountChanged count: Int) {
        let ownerRef = owner
        Task { @MainActor in ownerRef?.peersChanged(count) }
    }
}

public struct ContentView: View {
    @StateObject private var rt = AppRuntime()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            WebViewHost(player: rt.player)
                .frame(minWidth: 800, minHeight: 600)
            StatusBar(
                peerCount: .init(get: { rt.peerCount }, set: { _ in }),
                lastWriter: .init(get: { rt.lastWriter }, set: { _ in }),
                adShowing: .init(get: { rt.adShowing }, set: { _ in })
            )
        }
        .onAppear { rt.start() }
        .onDisappear { rt.stop() }
    }
}
