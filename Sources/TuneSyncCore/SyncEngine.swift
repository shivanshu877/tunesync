import Foundation

public final class SyncEngine: @unchecked Sendable {
    public let senderId: String
    public var adShowing: Bool = false

    private let broadcast: (SyncMessage) -> Void
    private var applyStateImpl: (PlayerState) -> Void
    private let clock = LamportClock()

    private var lastApplied: (ts: Int64, senderId: String) = (0, "")
    private var suppressUntil: Date = .distantPast
    private var lastLocalState: PlayerState?
    private var pendingLocalState: PlayerState?
    private var debounceWorkItem: DispatchWorkItem?
    private var heartbeatTimer: DispatchSourceTimer?

    private let debounceMs: Int
    private let suppressionMs: Int
    private let heartbeatSeconds: Int

    public init(
        senderId: String,
        broadcast: @escaping (SyncMessage) -> Void,
        applyState: @escaping (PlayerState) -> Void,
        debounceMs: Int = 200,
        suppressionMs: Int = 500,
        heartbeatSeconds: Int = 5
    ) {
        self.senderId = senderId
        self.broadcast = broadcast
        self.applyStateImpl = applyState
        self.debounceMs = debounceMs
        self.suppressionMs = suppressionMs
        self.heartbeatSeconds = heartbeatSeconds
    }

    public func applyStateOverride(_ apply: @escaping (PlayerState) -> Void) {
        applyStateImpl = apply
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + .seconds(heartbeatSeconds), repeating: .seconds(heartbeatSeconds))
        t.setEventHandler { [weak self] in self?.heartbeatTick() }
        t.resume()
        heartbeatTimer = t
    }

    public func stop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        debounceWorkItem?.cancel()
    }

    public func localStateChanged(_ state: PlayerState) {
        lastLocalState = state
        if Date() < suppressUntil { return }
        if adShowing { return }
        pendingLocalState = state
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushDebounce() }
        debounceWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(debounceMs),
            execute: work
        )
    }

    public func handleRemote(_ message: SyncMessage) {
        switch message {
        case .state(let s):
            guard s.senderId != senderId else { return }
            clock.observe(s.ts)
            let key = (s.ts, s.senderId)
            if !LamportClock.strictlyNewer(key, than: lastApplied) { return }
            lastApplied = key
            suppressUntil = Date().addingTimeInterval(Double(suppressionMs) / 1000.0)
            applyStateImpl(PlayerState(videoId: s.videoId, t: s.t, playing: s.playing))
        case .hello, .bye:
            break
        }
    }

    private func flushDebounce() {
        guard let s = pendingLocalState else { return }
        pendingLocalState = nil
        if Date() < suppressUntil { return }
        if adShowing { return }
        let ts = clock.tick()
        let msg = SyncMessage.state(StateMessage(
            senderId: senderId, ts: ts,
            videoId: s.videoId, t: s.t, playing: s.playing
        ))
        broadcast(msg)
    }

    private func heartbeatTick() {
        guard let s = lastLocalState else { return }
        if adShowing { return }
        let ts = clock.tick()
        let msg = SyncMessage.state(StateMessage(
            senderId: senderId, ts: ts,
            videoId: s.videoId, t: s.t, playing: s.playing
        ))
        broadcast(msg)
    }

    public func flushDebounceForTesting() {
        debounceWorkItem?.cancel()
        flushDebounce()
    }

    public func heartbeatTickForTesting() {
        heartbeatTick()
    }
}
