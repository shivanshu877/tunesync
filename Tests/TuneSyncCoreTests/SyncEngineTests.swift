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

    func testHeartbeatBroadcastsOnlyWhenHost() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "vid", t: 5, playing: true))
        e.flushDebounceForTesting()
        XCTAssertEqual(r.broadcasts.count, 1, "local change always broadcasts")

        e.heartbeatTickForTesting()
        XCTAssertEqual(r.broadcasts.count, 1, "heartbeat skipped when role is .unset")

        e.role = .guest
        e.heartbeatTickForTesting()
        XCTAssertEqual(r.broadcasts.count, 1, "heartbeat skipped when role is .guest")

        e.role = .host
        e.heartbeatTickForTesting()
        XCTAssertEqual(r.broadcasts.count, 2, "heartbeat fires when role is .host")
    }

    func testHostFlagAttachedToOutboundState() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.role = .host
        e.localStateChanged(PlayerState(videoId: "vid", t: 5, playing: true))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts[0] else {
            return XCTFail("expected state")
        }
        XCTAssertEqual(s.host, true)
    }

    func testHostFlagFalseWhenGuest() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.role = .guest
        e.localStateChanged(PlayerState(videoId: "vid", t: 5, playing: true))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts[0] else {
            return XCTFail("expected state")
        }
        XCTAssertEqual(s.host, false)
    }

    func testOutboundStateStampsClientMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        e.localStateChanged(PlayerState(videoId: "v", t: 1, playing: true))
        e.flushDebounceForTesting()
        let after = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertEqual(r.broadcasts.count, 1)
        guard case .state(let s) = r.broadcasts[0] else {
            return XCTFail("expected state")
        }
        XCTAssertNotNil(s.clientMs)
        XCTAssertGreaterThanOrEqual(s.clientMs!, before)
        XCTAssertLessThanOrEqual(s.clientMs!, after)
    }

    func testLatencyCompensationAdvancesPlayingT() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs - 500   // peer sent 500 ms ago
        )))
        XCTAssertEqual(r.applies.count, 1)
        // Should have advanced t by ~0.5s
        XCTAssertEqual(r.applies[0].t, 10.5, accuracy: 0.15)
    }

    func testLatencyCompensationSkippedForPause() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: false,
            clientMs: nowMs - 500
        )))
        XCTAssertEqual(r.applies.count, 1)
        // Pause: position is the literal pause point, no comp
        XCTAssertEqual(r.applies[0].t, 10.0, accuracy: 0.001)
    }

    func testLatencyCompensationCappedAt800ms() {
        // Defends against badly skewed Mac clocks: don't advance more than ~800ms.
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs - 60_000   // peer's clock claims 60s in the past
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.applies[0].t, 10.0, accuracy: 0.001)
    }

    func testLatencyCompensationAppliesUnder800ms() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs - 700   // 700ms — under cap, should comp
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.applies[0].t, 10.7, accuracy: 0.15)
    }

    func testLatencyCompensationSkippedForNegativeElapsed() {
        // Peer's clock is ahead of ours; we should NOT subtract.
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs + 5_000    // peer's clock 5s in the future
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.applies[0].t, 10.0, accuracy: 0.001)
    }

    func testMissingClientMsBackwardsCompat() {
        // Older clients won't send clientMs — must still apply.
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nil
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.applies[0].t, 10.0, accuracy: 0.001)
    }
}
