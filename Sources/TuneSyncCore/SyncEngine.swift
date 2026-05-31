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
    /// Apply callback `(state, startAtMs, clientMs, offsetMs)`.
    /// - `startAtMs` (local clock): non-nil only for track-change loads.
    /// - `clientMs`: host's wall-clock when the message was encoded — drives
    ///   the receiver's PLL math (`target_t = t + (hostNow - clientMs)/1000`).
    /// - `offsetMs`: host's clock offset relative to ours (already applied
    ///   to `startAtMs`, passed through so JS can convert `clientMs`).
    private var applyStateImpl: (PlayerState, Int64?, Int64?, Int64) -> Void
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

    /// Tracks the last *broadcasted* videoId so we can detect track-change
    /// transitions (which DO need a wall-clock schedule so peers have time
    /// to loadVideoById). Plain play / pause / seek don't need scheduling —
    /// the follower-side PLL converges from any starting drift.
    private var lastBroadcastVideoId: String?

    /// Maps a sender's id to the NTP-style estimate of (their clock − our clock) in ms.
    /// Subtract from a remote `startAtMs` to convert it into our local clock frame.
    /// Defaults to 0 so single-peer / no-ping cases behave as if clocks were synced.
    private let clockOffsetMsFor: (String) -> Int

    public init(
        senderId: String,
        broadcast: @escaping (SyncMessage) -> Void,
        applyState: @escaping (PlayerState, Int64?, Int64?, Int64) -> Void,
        debounceMs: Int = 200,
        suppressionMs: Int = 1500,
        heartbeatSeconds: Int = 1,
        applyOverheadMs: Int = 250,
        compCapMs: Int = 1500,
        scheduleBufferMs: Int = 300,
        clockOffsetMsFor: @escaping (String) -> Int = { _ in 0 }
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
        self.clockOffsetMsFor = clockOffsetMsFor
    }

    public func applyStateOverride(_ apply: @escaping (PlayerState, Int64?, Int64?, Int64) -> Void) {
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

            // Convert track-change `startAtMs` (host wall-clock) into our
            // local clock frame via the per-peer NTP-style offset.
            // Plain play/pause/seek carry no startAtMs — receiver-side PLL
            // (in JS) converges via continuous rate-bend instead.
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let offsetMs = Int64(clockOffsetMsFor(s.senderId))
            let localStartAt: Int64? = s.startAtMs.map { $0 - offsetMs }
            let isScheduled: Bool = (localStartAt ?? 0) > nowMs

            let compNote: String? = isScheduled
                ? "track-change +\((localStartAt ?? 0) - nowMs)ms (offset \(offsetMs)ms)"
                : nil

            applyStateImpl(
                PlayerState(videoId: s.videoId, t: s.t, playing: s.playing),
                isScheduled ? localStartAt : nil,
                s.clientMs,
                offsetMs
            )
            appendHistory(SyncEntry(
                direction: .applied, senderId: s.senderId,
                videoId: s.videoId, t: s.t, playing: s.playing,
                at: Date(), note: compNote
            ))
        case .hello, .bye, .ping, .pong:
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
        // Schedule a coordinated start ONLY on a real track change — both
        // peers need ~200 ms to loadVideoById. Plain play / pause / seek
        // broadcast immediately and let the receiver's PLL converge via
        // rate-bend; no pre-pause, no countdown overlay.
        let isTrackChange = (lastBroadcastVideoId != nil)
            && (lastBroadcastVideoId != s.videoId)
            && s.playing
        let scheduled = isTrackChange
        let msg = buildStateMessage(s, scheduled: scheduled)
        broadcast(msg)

        // Self-apply only for track change, so the host honors the same
        // load window as peers. Plain transitions are already in their
        // target state on the host (the user just acted on the player).
        if scheduled, let stateMsg = msg.stateOrNil() {
            applyStateImpl(s, stateMsg.startAtMs, nil, 0)
            if let startAt = stateMsg.startAtMs {
                let until = Date(timeIntervalSince1970: Double(startAt) / 1000.0)
                    .addingTimeInterval(0.5)
                suppressUntil = max(suppressUntil, until)
            }
        }

        lastBroadcastVideoId = s.videoId
        appendHistory(SyncEntry(
            direction: .sent, senderId: senderId,
            videoId: s.videoId, t: s.t, playing: s.playing,
            at: Date(),
            note: scheduled ? "track-change scheduled +\(scheduleBufferMs)ms" : "broadcast"
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
