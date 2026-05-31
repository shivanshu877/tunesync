import Foundation

public final class ClockSync {
    public struct Sample: Equatable {
        public let offsetMs: Int
        public let rttMs: Int
    }

    private var samples: [Sample] = []
    private let windowSize: Int

    public init(windowSize: Int = 5) {
        self.windowSize = windowSize
    }

    /// NTP-style sample.
    /// t0 = peer wallclock when ping sent
    /// t1 = our wallclock when ping received
    /// t2 = our wallclock when pong sent
    /// t3 = peer wallclock when pong received
    public func recordSample(t0: Int64, t1: Int64, t2: Int64, t3: Int64) {
        let rtt = Int((t3 - t0) - (t2 - t1))
        let offset = Int(((t1 - t0) + (t2 - t3)) / 2)
        samples.append(Sample(offsetMs: offset, rttMs: rtt))
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }
    }

    public func estimatedOffsetMs() -> Int {
        guard let best = samples.min(by: { $0.rttMs < $1.rttMs }) else { return 0 }
        return best.offsetMs
    }

    public func estimatedRttMs() -> Int {
        guard let best = samples.min(by: { $0.rttMs < $1.rttMs }) else { return 0 }
        return best.rttMs
    }
}
