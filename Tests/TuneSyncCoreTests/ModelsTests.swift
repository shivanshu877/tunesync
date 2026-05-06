import XCTest
@testable import TuneSyncCore

final class ModelsTests: XCTestCase {

    func testStateMessageRoundTrip() throws {
        let msg = SyncMessage.state(StateMessage(
            senderId: "abc",
            ts: 12345,
            videoId: "dQw4w9WgXcQ",
            t: 47.2,
            playing: true
        ))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        guard case .state(let s) = decoded else {
            return XCTFail("expected state case")
        }
        XCTAssertEqual(s.senderId, "abc")
        XCTAssertEqual(s.ts, 12345)
        XCTAssertEqual(s.videoId, "dQw4w9WgXcQ")
        XCTAssertEqual(s.t, 47.2, accuracy: 0.001)
        XCTAssertTrue(s.playing)
    }

    func testHelloMessageRoundTrip() throws {
        let msg = SyncMessage.hello(HelloMessage(senderId: "abc", displayName: "Mac of Asha"))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        guard case .hello(let h) = decoded else {
            return XCTFail("expected hello case")
        }
        XCTAssertEqual(h.senderId, "abc")
        XCTAssertEqual(h.displayName, "Mac of Asha")
    }

    func testByeMessageRoundTrip() throws {
        let msg = SyncMessage.bye(ByeMessage(senderId: "abc"))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(SyncMessage.self, from: data)
        guard case .bye(let b) = decoded else {
            return XCTFail("expected bye case")
        }
        XCTAssertEqual(b.senderId, "abc")
    }
}
