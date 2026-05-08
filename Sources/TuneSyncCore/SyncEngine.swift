import Foundation

public struct SyncEntry: Sendable, Equatable {
    public enum Direction: String, Sendable, Equatable {
        case sent, recv, applied, skipped
    }
    public let direction: Direction
    public let senderId: String
    public let videoId: String
    public let t: Double
    public let playing: Bool
    public let at: Date
    public let note: String?

    public init(direction: Direction, senderId: String, videoId: String, t: Double, playing: Bool, at: Date, note: String? = nil) {
        self.direction = direction
        self.senderId = senderId
        self.videoId = videoId
        self.t = t
        self.playing = playing
        self.at = at
        self.note = note
    }
}

public enum Role: String, Sendable, Equatable {
    /// Default state — no one's claimed host yet. Heartbeats are silenced.
    /// Outbound state still goes on user-driven local change.
    case unset
    /// Authoritative source. Only the host's heartbeat broadcasts.
    case host
    /// Reacts to remote state and to local user actions, but never heartbeats.
    case guest
}

public final class SyncEngine: @unchecked Sendable {
    public let senderId: String

    /// Current role. Heartbeats only fire when role == .host. Local changes
    /// still broadcast in any role (so anyone can hit pause and have it
    /// propagate — guests just don't keep reasserting their position).
    public var role: Role = .unset

    public var adShowing: Bool = false {
        didSet {
            if adShowing != oldValue {
                appendHistory(SyncEntry(
                    direction: .skipped, senderId: senderId,
                    videoId: lastLocalState?.videoId ?? "—",
                    t: lastLocalState?.t ?? 0,
                    playing: lastLocalState?.playing ?? false,
                    at: Date(),
                    note: adShowing ? "ad started — outbound suppressed" : "ad ended"
                ))
            }
        }
    }

    public private(set) var history: [SyncEntry] = []
    public var onHistoryChanged: (() -> Void)?
    private let historyCap = 30

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
        suppressionMs: Int = 1500,
        heartbeatSeconds: Int = 3
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
            appendHistory(SyncEntry(
                direction: .recv, senderId: s.senderId,
                videoId: s.videoId, t: s.t, playing: s.playing,
                at: Date()
            ))
            guard s.senderId != senderId else { return }
            clock.observe(s.ts)
            let key = (s.ts, s.senderId)
            if !LamportClock.strictlyNewer(key, than: lastApplied) {
                appendHistory(SyncEntry(
                    direction: .skipped, senderId: s.senderId,
                    videoId: s.videoId, t: s.t, playing: s.playing,
                    at: Date(), note: "stale — older than lastApplied"
                ))
                return
            }
            lastApplied = key
            suppressUntil = Date().addingTimeInterval(Double(suppressionMs) / 1000.0)

            // Latency compensation: if peer is playing, advance `t` by however
            // long the message took to reach us. Capped at 800ms — typical LAN
            // RTT is <20ms; anything beyond ~800ms is more likely to be Mac
            // clock skew than real network delay.
            var effectiveT = s.t
            var compNote: String? = nil
            if s.playing, let cms = s.clientMs {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let elapsedMs = nowMs - cms
                if elapsedMs > 0 && elapsedMs < 800 {
                    effectiveT += Double(elapsedMs) / 1000.0
                    compNote = "+\(elapsedMs)ms latency comp"
                }
            }

            applyStateImpl(PlayerState(videoId: s.videoId, t: effectiveT, playing: s.playing))
            appendHistory(SyncEntry(
                direction: .applied, senderId: s.senderId,
                videoId: s.videoId, t: effectiveT, playing: s.playing,
                at: Date(), note: compNote
            ))
        case .hello, .bye:
            break
        }
    }

    private func flushDebounce() {
        guard let s = pendingLocalState else { return }
        pendingLocalState = nil
        if Date() < suppressUntil {
            appendHistory(SyncEntry(
                direction: .skipped, senderId: senderId,
                videoId: s.videoId, t: s.t, playing: s.playing,
                at: Date(), note: "debounce suppressed (post-apply window)"
            ))
            return
        }
        if adShowing {
            appendHistory(SyncEntry(
                direction: .skipped, senderId: senderId,
                videoId: s.videoId, t: s.t, playing: s.playing,
                at: Date(), note: "ad showing"
            ))
            return
        }
        let msg = buildStateMessage(s)
        broadcast(msg)
        appendHistory(SyncEntry(
            direction: .sent, senderId: senderId,
            videoId: s.videoId, t: s.t, playing: s.playing,
            at: Date(), note: "debounced"
        ))
    }

    private func heartbeatTick() {
        // Only the host heartbeats. Guests/unset never reassert their
        // position on a timer — that was the source of the sync war.
        guard role == .host else { return }
        guard let s = lastLocalState else { return }
        if adShowing { return }
        let msg = buildStateMessage(s)
        broadcast(msg)
        appendHistory(SyncEntry(
            direction: .sent, senderId: senderId,
            videoId: s.videoId, t: s.t, playing: s.playing,
            at: Date(), note: "host heartbeat"
        ))
    }

    private func buildStateMessage(_ s: PlayerState) -> SyncMessage {
        let ts = clock.tick()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return SyncMessage.state(StateMessage(
            senderId: senderId, ts: ts,
            videoId: s.videoId, t: s.t, playing: s.playing,
            clientMs: nowMs,
            host: role == .host
        ))
    }

    private func appendHistory(_ entry: SyncEntry) {
        history.append(entry)
        if history.count > historyCap {
            history.removeFirst(history.count - historyCap)
        }
        onHistoryChanged?()
    }

    public func flushDebounceForTesting() {
        debounceWorkItem?.cancel()
        flushDebounce()
    }

    public func heartbeatTickForTesting() {
        heartbeatTick()
    }
}
