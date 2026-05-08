import XCTest
@testable import TuneSyncCore

final class SyncEngineApplyAtTests: XCTestCase {
    func testApplyAtAdvancesTPositionForFutureTarget() {
        var applied: PlayerState?
        let engine = SyncEngine(
            senderId: "self",
            broadcast: { _ in },
            applyState: { applied = $0 }
        )
        engine.peerOffsetLookup = { _ in 0 }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = SyncMessage.state(StateMessage(
            senderId: "host", ts: 1,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs, host: true,
            applyAtMs: nowMs + 200,
            adOnHost: false
        ))
        engine.handleRemote(msg)
        guard let a = applied else { return XCTFail("not applied") }
        XCTAssertEqual(a.t, 10.2, accuracy: 0.05)
    }

    func testOffsetSubtractedFromTarget() {
        var applied: PlayerState?
        let engine = SyncEngine(
            senderId: "self",
            broadcast: { _ in },
            applyState: { applied = $0 }
        )
        engine.peerOffsetLookup = { _ in 500 }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = SyncMessage.state(StateMessage(
            senderId: "host", ts: 1,
            videoId: "vid", t: 5.0, playing: true,
            clientMs: nowMs, host: true,
            applyAtMs: nowMs + 700,
            adOnHost: false
        ))
        engine.handleRemote(msg)
        guard let a = applied else { return XCTFail("not applied") }
        XCTAssertEqual(a.t, 5.2, accuracy: 0.05)
    }
}
