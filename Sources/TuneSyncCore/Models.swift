import Foundation

public enum TuneSyncCore {
    public static let version = "0.1.0-dev"
}

public struct PlayerState: Codable, Equatable, Sendable {
    public var videoId: String
    public var t: Double
    public var playing: Bool

    public init(videoId: String, t: Double, playing: Bool) {
        self.videoId = videoId
        self.t = t
        self.playing = playing
    }
}

public struct StateMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let ts: Int64
    public let videoId: String
    public let t: Double
    public let playing: Bool
    /// Sender's wall-clock (ms since epoch) when the message was encoded.
    public let clientMs: Int64?
    /// True if the sender is currently claiming the host role. Used so
    /// receivers know which peer to treat as the authoritative heartbeat
    /// source. Optional for backwards compat.
    public let host: Bool?

    public init(senderId: String, ts: Int64, videoId: String, t: Double, playing: Bool, clientMs: Int64? = nil, host: Bool? = nil) {
        self.senderId = senderId
        self.ts = ts
        self.videoId = videoId
        self.t = t
        self.playing = playing
        self.clientMs = clientMs
        self.host = host
    }
}

public struct HelloMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let displayName: String
    public let host: Bool?

    public init(senderId: String, displayName: String, host: Bool? = nil) {
        self.senderId = senderId
        self.displayName = displayName
        self.host = host
    }
}

public struct ByeMessage: Codable, Equatable, Sendable {
    public let senderId: String

    public init(senderId: String) {
        self.senderId = senderId
    }
}

public enum SyncMessage: Codable, Equatable, Sendable {
    case state(StateMessage)
    case hello(HelloMessage)
    case bye(ByeMessage)

    private enum Kind: String, Codable {
        case state, hello, bye
    }

    private enum Keys: String, CodingKey {
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .state: self = .state(try StateMessage(from: decoder))
        case .hello: self = .hello(try HelloMessage(from: decoder))
        case .bye:   self = .bye(try ByeMessage(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .state(let m):
            try c.encode(Kind.state, forKey: .kind)
            try m.encode(to: encoder)
        case .hello(let m):
            try c.encode(Kind.hello, forKey: .kind)
            try m.encode(to: encoder)
        case .bye(let m):
            try c.encode(Kind.bye, forKey: .kind)
            try m.encode(to: encoder)
        }
    }
}
