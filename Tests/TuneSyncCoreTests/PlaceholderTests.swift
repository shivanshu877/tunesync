import XCTest
@testable import TuneSyncCore

final class PlaceholderTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(TuneSyncCore.version, "0.1.0-dev")
    }
}
