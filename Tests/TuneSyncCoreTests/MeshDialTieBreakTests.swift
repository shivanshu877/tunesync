import XCTest
@testable import TuneSyncCore

final class MeshDialTieBreakTests: XCTestCase {
    func testLowerSenderIdDials() {
        XCTAssertTrue(MeshPolicy.shouldDial(localId: "alice", remoteId: "bob"))
        XCTAssertFalse(MeshPolicy.shouldDial(localId: "bob", remoteId: "alice"))
    }

    func testEqualIdsDoNotDial() {
        XCTAssertFalse(MeshPolicy.shouldDial(localId: "x", remoteId: "x"))
    }
}
