import Foundation

public enum FrameError: Error, Equatable {
    case oversize(declared: Int, max: Int)
}

public enum FrameCodec {
    public static func encode(_ payload: Data) -> Data {
        var out = Data(capacity: 4 + payload.count)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

public struct FrameParser {
    public let maxPayloadBytes: Int
    private var buffer = Data()
    private var pendingError: FrameError?

    public init(maxPayloadBytes: Int = 1 << 20) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    public mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    public mutating func drain() -> [Data] {
        var frames: [Data] = []
        while true {
            do {
                if let f = try takeOne() {
                    frames.append(f)
                } else {
                    break
                }
            } catch {
                break
            }
        }
        return frames
    }

    public mutating func drainStrict() throws -> [Data] {
        var frames: [Data] = []
        while let f = try takeOne() {
            frames.append(f)
        }
        if let err = pendingError {
            pendingError = nil
            throw err
        }
        return frames
    }

    private mutating func takeOne() throws -> Data? {
        if let err = pendingError {
            pendingError = nil
            throw err
        }
        guard buffer.count >= 4 else { return nil }
        let lenBytes = buffer.prefix(4)
        let len = lenBytes.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        let n = Int(len)
        if n > maxPayloadBytes {
            buffer.removeAll()
            pendingError = .oversize(declared: n, max: maxPayloadBytes)
            throw pendingError!
        }
        guard buffer.count >= 4 + n else { return nil }
        let payload = buffer.subdata(in: 4..<(4 + n))
        buffer.removeSubrange(0..<(4 + n))
        return payload
    }
}
