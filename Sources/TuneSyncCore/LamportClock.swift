import Foundation

public final class LamportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: Int64

    public init() {
        self.counter = Self.systemNow()
    }

    public func tick() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let n = max(counter + 1, Self.systemNow())
        counter = n
        return n
    }

    public func observe(_ remote: Int64) {
        lock.lock(); defer { lock.unlock() }
        if remote > counter { counter = remote }
    }

    public func now() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return counter
    }

    public static func strictlyNewer(
        _ a: (ts: Int64, senderId: String),
        than b: (ts: Int64, senderId: String)
    ) -> Bool {
        if a.ts != b.ts { return a.ts > b.ts }
        return a.senderId > b.senderId
    }

    private static func systemNow() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
