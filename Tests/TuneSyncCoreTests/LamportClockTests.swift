import XCTest
@testable import TuneSyncCore

final class LamportClockTests: XCTestCase {

    func testTickIsMonotonic() {
        let clock = LamportClock()
        let a = clock.tick()
        let b = clock.tick()
        XCTAssertGreaterThan(b, a)
    }

    func testObserveAdvancesPastIncomingTimestamp() {
        let clock = LamportClock()
        let future = clock.now() + 10_000
        clock.observe(future)
        let next = clock.tick()
        XCTAssertGreaterThan(next, future)
    }

    func testObserveDoesNotRewind() {
        let clock = LamportClock()
        let a = clock.tick()
        clock.observe(a - 5000)
        let b = clock.tick()
        XCTAssertGreaterThan(b, a)
    }

    func testStrictlyNewerComparesTimestampThenSenderId() {
        XCTAssertTrue(LamportClock.strictlyNewer((100, "B"), than: (100, "A")))
        XCTAssertFalse(LamportClock.strictlyNewer((100, "A"), than: (100, "B")))
        XCTAssertTrue(LamportClock.strictlyNewer((101, "A"), than: (100, "Z")))
        XCTAssertFalse(LamportClock.strictlyNewer((100, "A"), than: (100, "A")))
    }
}
