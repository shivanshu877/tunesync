import XCTest
import Network
@testable import TuneSyncCore

final class BridgeHTTPTests: XCTestCase {
    func testServesIndex() throws {
        let bridge = Bridge(port: 18732, room: "test")
        try bridge.start()
        defer { bridge.stop() }
        let url = URL(string: "http://127.0.0.1:18732/")!
        let exp = expectation(description: "fetch")
        URLSession.shared.dataTask(with: url) { data, _, err in
            defer { exp.fulfill() }
            guard err == nil, let d = data, let s = String(data: d, encoding: .utf8) else {
                XCTFail("\(String(describing: err))"); return
            }
            XCTAssertTrue(s.contains("TuneSync Web"))
        }.resume()
        wait(for: [exp], timeout: 3.0)
    }

    func testServesAppJS() throws {
        let bridge = Bridge(port: 18733, room: "test")
        try bridge.start()
        defer { bridge.stop() }
        let url = URL(string: "http://127.0.0.1:18733/app.js")!
        let exp = expectation(description: "fetch")
        URLSession.shared.dataTask(with: url) { data, _, err in
            defer { exp.fulfill() }
            XCTAssertNil(err)
            XCTAssertNotNil(data)
            if let d = data, let s = String(data: d, encoding: .utf8) {
                XCTAssertTrue(s.contains("YT.Player"))
            }
        }.resume()
        wait(for: [exp], timeout: 3.0)
    }
}
