import XCTest
@testable import TuneSyncCore

final class ClockSyncTests: XCTestCase {
    func testOffsetAndRttFromSingleSample() {
        let cs = ClockSync(windowSize: 5)
        cs.recordSample(t0: 0, t1: 1050, t2: 1052, t3: 102)
        XCTAssertEqual(cs.estimatedOffsetMs(), 1000)
        XCTAssertEqual(cs.estimatedRttMs(), 100)
    }

    func testWindowPicksLowestRtt() {
        let cs = ClockSync(windowSize: 5)
        cs.recordSample(t0: 0, t1: 1050, t2: 1052, t3: 102)
        cs.recordSample(t0: 200, t1: 1700, t2: 1701, t3: 700)
        XCTAssertEqual(cs.estimatedOffsetMs(), 1000)
        XCTAssertEqual(cs.estimatedRttMs(), 100)
    }

    func testEmptyReturnsZero() {
        let cs = ClockSync(windowSize: 5)
        XCTAssertEqual(cs.estimatedOffsetMs(), 0)
        XCTAssertEqual(cs.estimatedRttMs(), 0)
    }

    func testWindowRolls() {
        let cs = ClockSync(windowSize: 2)
        cs.recordSample(t0: 0, t1: 100, t2: 100, t3: 100)
        cs.recordSample(t0: 0, t1: 200, t2: 200, t3: 200)
        cs.recordSample(t0: 0, t1: 300, t2: 300, t3: 300)
        XCTAssertEqual(cs.estimatedOffsetMs(), 100)
    }
}
