import XCTest
@testable import TuneSyncCore

final class FrameCodecTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let payload = "hello".data(using: .utf8)!
        let encoded = FrameCodec.encode(payload)
        var parser = FrameParser()
        parser.append(encoded)
        let frames = parser.drain()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], payload)
    }

    func testPartialBufferAccumulates() throws {
        let payload = "hello world".data(using: .utf8)!
        let encoded = FrameCodec.encode(payload)
        var parser = FrameParser()
        parser.append(encoded.prefix(3))
        XCTAssertEqual(parser.drain().count, 0)
        parser.append(encoded.dropFirst(3).prefix(5))
        XCTAssertEqual(parser.drain().count, 0)
        parser.append(encoded.dropFirst(8))
        let frames = parser.drain()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], payload)
    }

    func testTwoFramesInOneBuffer() throws {
        let p1 = "first".data(using: .utf8)!
        let p2 = "second".data(using: .utf8)!
        var buf = Data()
        buf.append(FrameCodec.encode(p1))
        buf.append(FrameCodec.encode(p2))
        var parser = FrameParser()
        parser.append(buf)
        let frames = parser.drain()
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0], p1)
        XCTAssertEqual(frames[1], p2)
    }

    func testOversizeFrameThrows() throws {
        var parser = FrameParser(maxPayloadBytes: 16)
        var oversize = Data([0, 0, 0, 32])
        oversize.append(Data(repeating: 0x41, count: 32))
        parser.append(oversize)
        XCTAssertThrowsError(try parser.drainStrict())
    }
}
