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
    /// Apply callback receives `(state, startAtMs)`. If `startAtMs` is
    /// non-nil and in the future, the apply layer must schedule the
    /// play() to fire at that wall-clock time (vs immediate apply).
    private var applyStateImpl: (PlayerState, Int64?) -> Void
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

    /// Estimated time between "we received the host's state message" and
    /// "the WebView's <video> element actually finished seeking" — bridge
    /// dispatch + JS evaluation + DOM update + DASH segment fetch + seek
    /// complete. We add this to the network-elapsed compensation so the
    /// receiver lands on "where the host will be when seek finishes,"
    /// not "where the host was when the message left."
    private let applyOverheadMs: Int

    /// Maximum total compensation we'll apply (network elapsed + apply
    /// overhead). Defends against pathological clock skew while still
    /// covering realistic LAN RTT (typically <100 ms) plus worst-case
    /// Wi-Fi jitter (a few hundred ms).
    private let compCapMs: Int

    /// Buffer between "we want to play" and "play actually fires" on every
    /// peer. This is the wall-clock head-start we give the slowest peer
    /// to receive the message + load the segment + queue up. Trades a
    /// click-to-audio delay for perfect cross-Mac sync at the play moment.
    private let scheduleBufferMs: Int

    /// Tracks last *broadcasted* playing state so we can tell transitions
    /// (paused → playing) apart from steady-state heartbeats.
    private var lastBroadcastPlaying: Bool = false

    public init(
        senderId: String,
        broadcast: @escaping (SyncMessage) -> Void,
        applyState: @escaping (PlayerState, Int64?) -> Void,
        debounceMs: Int = 200,
        suppressionMs: Int = 1500,
        heartbeatSeconds: Int = 1,
        applyOverheadMs: Int = 250,
        compCapMs: Int = 1500,
        scheduleBufferMs: Int = 3000
    ) {
        self.senderId = senderId
        self.broadcast = broadcast
        self.applyStateImpl = applyState
        self.debounceMs = debounceMs
        self.suppressionMs = suppressionMs
        self.heartbeatSeconds = heartbeatSeconds
        self.applyOverheadMs = applyOverheadMs
        self.compCapMs = compCapMs
        self.scheduleBufferMs = scheduleBufferMs
    }

    public func applyStateOverride(_ apply: @escaping (PlayerState, Int64?) -> Void) {
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

            // If the message is scheduled (startAtMs present and in the
            // future), don't apply latency comp — the schedule itself
            // handles inter-Mac alignment by virtue of all peers waiting
            // for the same wall-clock instant.
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let isScheduled = (s.startAtMs ?? 0) > nowMs

            var effectiveT = s.t
            var compNote: String? = nil
            if !isScheduled, s.playing, let cms = s.clientMs {
                let networkMs = nowMs - cms
                if networkMs >= 0 {
                    let totalMs = min(networkMs + Int64(applyOverheadMs), Int64(compCapMs))
                    if totalMs > 0 {
                        effectiveT += Double(totalMs) / 1000.0
                        compNote = "+\(totalMs)ms (\(networkMs)net + \(applyOverheadMs)apply)"
                    }
                }
            } else if isScheduled {
                let inMs = (s.startAtMs ?? 0) - nowMs
                compNote = "scheduled +\(inMs)ms"
            }

            applyStateImpl(
                PlayerState(videoId: s.videoId, t: effectiveT, playing: s.playing),
                isScheduled ? s.startAtMs : nil
            )
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
        // Schedule a coordinated start whenever the broadcast carries
        // playing=true. Both peers (host and guest) wait for the same
        // wall-clock instant before triggering v.play(). Pauses are
        // not scheduled — they propagate immediately.
        let scheduled = s.playing
        let msg = buildStateMessage(s, scheduled: scheduled)
        broadcast(msg)

        // Apply locally with the same schedule, so the host (or whoever
        // initiated the action) honors the buffer too. Without this,
        // the host plays immediately and is ~250ms ahead of every peer.
        if scheduled, let stateMsg = msg.stateOrNil() {
            applyStateImpl(s, stateMsg.startAtMs)
        }

        lastBroadcastPlaying = s.playing
        appendHistory(SyncEntry(
            direction: .sent, senderId: senderId,
            videoId: s.videoId, t: s.t, playing: s.playing,
            at: Date(),
            note: scheduled ? "scheduled +\(scheduleBufferMs)ms" : "debounced"
        ))
    }

    private func heartbeatTick() {
        // Only the host heartbeats. Guests/unset never reassert their
        // position on a timer — that was the source of the sync war.
        guard role == .host else { return }
        guard let s = lastLocalState else { return }
        if adShowing { return }
        // Heartbeats are never scheduled — they're continuous re-anchoring
        // of an in-progress playback, not a new "play" event.
        let msg = buildStateMessage(s, scheduled: false)
        broadcast(msg)
        appendHistory(SyncEntry(
            direction: .sent, senderId: senderId,
            videoId: s.videoId, t: s.t, playing: s.playing,
            at: Date(), note: "host heartbeat"
        ))
    }

    private func buildStateMessage(_ s: PlayerState, scheduled: Bool) -> SyncMessage {
        let ts = clock.tick()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startAt: Int64? = scheduled ? (nowMs + Int64(scheduleBufferMs)) : nil
        return SyncMessage.state(StateMessage(
            senderId: senderId, ts: ts,
            videoId: s.videoId, t: s.t, playing: s.playing,
            clientMs: nowMs,
            host: role == .host,
            startAtMs: startAt
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
