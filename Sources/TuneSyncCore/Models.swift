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
    /// True if the sender is currently claiming the host role.
    public let host: Bool?
    /// Sender's wallclock target time when this state should take effect.
    public let applyAtMs: Int64?
    /// True if the host is currently in an ad — guests should mute and pause.
    public let adOnHost: Bool?

    public init(senderId: String, ts: Int64, videoId: String, t: Double, playing: Bool,
                clientMs: Int64? = nil, host: Bool? = nil,
                applyAtMs: Int64? = nil, adOnHost: Bool? = nil) {
        self.senderId = senderId
        self.ts = ts
        self.videoId = videoId
        self.t = t
        self.playing = playing
        self.clientMs = clientMs
        self.host = host
        self.applyAtMs = applyAtMs
        self.adOnHost = adOnHost
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

public struct PingMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let nonce: Int64
    /// Sender wallclock (ms) when this ping was encoded.
    public let t0: Int64

    public init(senderId: String, nonce: Int64, t0: Int64 = 0) {
        self.senderId = senderId
        self.nonce = nonce
        self.t0 = t0
    }
}

public struct PongMessage: Codable, Equatable, Sendable {
    public let senderId: String
    public let nonce: Int64
    /// Echoed from the originating ping.
    public let t0: Int64
    /// Receiver wallclock (ms) at receive.
    public let t1: Int64
    /// Receiver wallclock (ms) at send.
    public let t2: Int64

    public init(senderId: String, nonce: Int64, t0: Int64 = 0, t1: Int64 = 0, t2: Int64 = 0) {
        self.senderId = senderId
        self.nonce = nonce
        self.t0 = t0
        self.t1 = t1
        self.t2 = t2
    }
}

public enum SyncMessage: Codable, Equatable, Sendable {
    case state(StateMessage)
    case hello(HelloMessage)
    case bye(ByeMessage)
    case ping(PingMessage)
    case pong(PongMessage)

    private enum Kind: String, Codable {
        case state, hello, bye, ping, pong
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
        case .ping:  self = .ping(try PingMessage(from: decoder))
        case .pong:  self = .pong(try PongMessage(from: decoder))
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
        case .ping(let m):
            try c.encode(Kind.ping, forKey: .kind)
            try m.encode(to: encoder)
        case .pong(let m):
            try c.encode(Kind.pong, forKey: .kind)
            try m.encode(to: encoder)
        }
    }
}
