import XCTest
@testable import TuneSyncCore

final class MeshLivenessTests: XCTestCase {
    func testIdleWhenRecentTraffic() {
        let now = Date(timeIntervalSince1970: 1000)
        let action = MeshPolicy.livenessAction(
            now: now,
            lastSeen: now.addingTimeInterval(-1),
            lastPingSent: now.addingTimeInterval(-30),
            pingIntervalS: 10,
            deadAfterS: 25
        )
        XCTAssertEqual(action, .idle)
    }

    func testSendPingAfterSilence() {
        let now = Date(timeIntervalSince1970: 1000)
        let action = MeshPolicy.livenessAction(
            now: now,
            lastSeen: now.addingTimeInterval(-12),
            lastPingSent: now.addingTimeInterval(-12),
            pingIntervalS: 10,
            deadAfterS: 25
        )
        XCTAssertEqual(action, .sendPing)
    }

    func testDropAfterDeadWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let action = MeshPolicy.livenessAction(
            now: now,
            lastSeen: now.addingTimeInterval(-30),
            lastPingSent: now.addingTimeInterval(-15),
            pingIntervalS: 10,
            deadAfterS: 25
        )
        XCTAssertEqual(action, .dropDead)
    }

    func testBackoffSchedule() {
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 0), 1)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 1), 2)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 2), 5)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 3), 10)
        XCTAssertEqual(MeshPolicy.restartBackoff(attempt: 99), 10)
    }
}
