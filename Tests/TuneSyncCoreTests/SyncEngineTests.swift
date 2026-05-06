import XCTest
@testable import TuneSyncCore

final class SyncEngineTests: XCTestCase {

    final class Recorder {
        var broadcasts: [SyncMessage] = []
        var applies: [PlayerState] = []
    }

    private func makeEngine(
        senderId: String = "self",
        recorder: Recorder
    ) -> SyncEngine {
        return SyncEngine(
            senderId: senderId,
            broadcast: { recorder.broadcasts.append($0) },
            applyState: { recorder.applies.append($0) }
        )
    }

    func testLocalChangeBroadcasts() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "vid1", t: 10, playing: true))
        e.flushDebounceForTesting()
        XCTAssertEqual(r.broadcasts.count, 1)
        guard case .state(let s) = r.broadcasts[0] else {
            return XCTFail("expected state")
        }
        XCTAssertEqual(s.senderId, "self")
        XCTAssertEqual(s.videoId, "vid1")
        XCTAssertTrue(s.playing)
    }

    func testRemoteNewerStateApplies() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let incoming = SyncMessage.state(StateMessage(
            senderId: "peer",
            ts: 9_999_999_999_999,
            videoId: "vid2",
            t: 30,
            playing: true
        ))
        e.handleRemote(incoming)
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.applies[0].videoId, "vid2")
    }

    func testRemoteOlderStateIgnored() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.handleRemote(.state(StateMessage(
            senderId: "peer",
            ts: 1000,
            videoId: "vid1", t: 10, playing: true
        )))
        XCTAssertEqual(r.applies.count, 1)
        e.handleRemote(.state(StateMessage(
            senderId: "peer",
            ts: 500,
            videoId: "vid2", t: 20, playing: false
        )))
        XCTAssertEqual(r.applies.count, 1, "older should be ignored")
    }

    func testEchoFromOwnSenderIdIgnored() {
        let r = Recorder()
        let e = makeEngine(senderId: "self", recorder: r)
        e.handleRemote(.state(StateMessage(
            senderId: "self",
            ts: 9_999_999_999_999,
            videoId: "vid", t: 0, playing: true
        )))
        XCTAssertEqual(r.applies.count, 0)
    }

    func testSuppressionAfterApplyPreventsImmediateBroadcast() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.handleRemote(.state(StateMessage(
            senderId: "peer",
            ts: 1000,
            videoId: "vidX", t: 5, playing: true
        )))
        XCTAssertEqual(r.applies.count, 1)
        e.localStateChanged(PlayerState(videoId: "vidX", t: 5, playing: true))
        e.flushDebounceForTesting()
        XCTAssertEqual(r.broadcasts.count, 0, "echo should be suppressed")
    }

    func testAdSuppressionBlocksOutboundButAllowsInbound() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.adShowing = true
        e.localStateChanged(PlayerState(videoId: "vidY", t: 0, playing: true))
        e.flushDebounceForTesting()
        XCTAssertEqual(r.broadcasts.count, 0)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 9_000_000_000_000,
            videoId: "vidZ", t: 12, playing: true
        )))
        XCTAssertEqual(r.applies.count, 1)
    }

    func testHeartbeatBroadcastsCurrentState() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "vid", t: 5, playing: true))
        e.flushDebounceForTesting()
        XCTAssertEqual(r.broadcasts.count, 1)
        e.heartbeatTickForTesting()
        XCTAssertEqual(r.broadcasts.count, 2)
    }
}
