import XCTest
@testable import TuneSyncCore

final class MeshHelloCollisionTests: XCTestCase {
    func testCollisionAlwaysKeepsExisting() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 1005)
        XCTAssertFalse(PeerMesh.shouldReplaceExistingPeer(
            existingConnectedAt: earlier,
            newHelloAt: later
        ))
    }
}
