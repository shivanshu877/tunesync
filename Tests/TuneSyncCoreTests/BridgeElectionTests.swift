import XCTest
@testable import TuneSyncCore

final class BridgeElectionTests: XCTestCase {
    func testLowestIdAmongMacsWins() {
        XCTAssertTrue(BridgeElection.shouldBridge(localId: "alice", peerIds: ["bob", "carol"]))
        XCTAssertFalse(BridgeElection.shouldBridge(localId: "bob", peerIds: ["alice", "carol"]))
    }

    func testSoloMacBridges() {
        XCTAssertTrue(BridgeElection.shouldBridge(localId: "alice", peerIds: []))
    }

    func testEqualIdImpossibleButHandled() {
        XCTAssertTrue(BridgeElection.shouldBridge(localId: "x", peerIds: ["x"]))
    }
}
