import Foundation

public enum LivenessAction: Equatable, Sendable {
    case idle
    case sendPing
    case dropDead
}

public enum MeshPolicy {
    /// Tie-break for simultaneous-dial races. The peer with the
    /// lexicographically smaller senderId initiates the TCP connection;
    /// the other waits for incoming hello.
    public static func shouldDial(localId: String, remoteId: String) -> Bool {
        return localId < remoteId
    }

    public static func livenessAction(
        now: Date,
        lastSeen: Date,
        lastPingSent: Date,
        pingIntervalS: TimeInterval,
        deadAfterS: TimeInterval
    ) -> LivenessAction {
        let silenceFromLastSeen = now.timeIntervalSince(lastSeen)
        if silenceFromLastSeen >= deadAfterS { return .dropDead }
        let sincePing = now.timeIntervalSince(lastPingSent)
        if silenceFromLastSeen >= pingIntervalS && sincePing >= pingIntervalS {
            return .sendPing
        }
        return .idle
    }

    /// Exponential-ish backoff schedule for restart attempts on listener,
    /// browser, or path failures. Capped to keep retries cheap.
    public static func restartBackoff(attempt: Int) -> TimeInterval {
        switch attempt {
        case 0: return 1
        case 1: return 2
        case 2: return 5
        default: return 10
        }
    }
}
