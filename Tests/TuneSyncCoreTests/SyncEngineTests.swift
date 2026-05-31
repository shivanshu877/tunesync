import XCTest
@testable import TuneSyncCore

final class SyncEngineTests: XCTestCase {

    final class Recorder {
        var broadcasts: [SyncMessage] = []
        var applies: [PlayerState] = []
        var appliesScheduledAt: [Int64?] = []
        var appliesClientMs: [Int64?] = []
        var appliesOffsetMs: [Int64] = []
    }

    private func makeEngine(
        senderId: String = "self",
        recorder: Recorder,
        clockOffsetMsFor: @escaping (String) -> Int = { _ in 0 }
    ) -> SyncEngine {
        return SyncEngine(
            senderId: senderId,
            broadcast: { recorder.broadcasts.append($0) },
            applyState: { state, startAtMs, clientMs, offsetMs in
                recorder.applies.append(state)
                recorder.appliesScheduledAt.append(startAtMs)
                recorder.appliesClientMs.append(clientMs)
                recorder.appliesOffsetMs.append(offsetMs)
            },
            clockOffsetMsFor: clockOffsetMsFor
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

    // MARK: - PLL-follower model

    func testPlainPlayBroadcastsNoStartAtMs() {
        // Plain play on the existing track must NOT schedule.
        // Receiver-side PLL handles convergence via rate-bend.
        let r = Recorder()
        let e = makeEngine(recorder: r)
        // Establish a prior broadcast so lastBroadcastVideoId is set.
        e.localStateChanged(PlayerState(videoId: "v", t: 0, playing: false))
        e.flushDebounceForTesting()
        e.localStateChanged(PlayerState(videoId: "v", t: 0, playing: true))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNil(s.startAtMs, "plain play (same videoId) must not schedule")
        XCTAssertTrue(s.playing)
    }

    func testPauseBroadcastsNoStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "v", t: 10, playing: false))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNil(s.startAtMs, "pause must never schedule")
    }

    func testTrackChangeBroadcastsCarryStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        // First track establishes lastBroadcastVideoId.
        e.localStateChanged(PlayerState(videoId: "first", t: 30, playing: true))
        e.flushDebounceForTesting()
        // Second broadcast switches videoId while playing — track change.
        e.localStateChanged(PlayerState(videoId: "second", t: 0, playing: true))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNotNil(s.startAtMs, "track change must schedule so peers can load")
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertTrue(abs(s.startAtMs! - (nowMs + 300)) <= 300,
            "track-change schedule should be ~300ms in future")
    }

    func testApplyForwardsClientMsAndOffsetForPLL() {
        // Receivers need clientMs + offsetMs to do PLL math in JS.
        let r = Recorder()
        let e = makeEngine(recorder: r, clockOffsetMsFor: { _ in 1234 })
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 9_000_000_000_000,
            videoId: "v", t: 10.0, playing: true,
            clientMs: nowMs - 100
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.appliesClientMs[0], nowMs - 100,
            "clientMs forwarded to apply for receiver PLL")
        XCTAssertEqual(r.appliesOffsetMs[0], 1234,
            "offsetMs forwarded to apply for receiver PLL")
        // No latency comp on t — JS-side PLL handles it.
        XCTAssertEqual(r.applies[0].t, 10.0, accuracy: 0.001)
    }

    func testRemoteTrackChangeStartAtMsForwarded() {
        // Track-change messages still carry startAtMs (host wall-clock),
        // and apply must forward it in OUR local clock frame.
        let r = Recorder()
        let e = makeEngine(recorder: r, clockOffsetMsFor: { _ in 0 })
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 9_000_000_000_000,
            videoId: "v", t: 0.0, playing: true,
            clientMs: nowMs,
            startAtMs: nowMs + 500
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.appliesScheduledAt[0], nowMs + 500,
            "track-change startAtMs forwarded (offset=0 here)")
    }

    func testRemotePlainPlayHasNoScheduledAt() {
        // A plain (non-track-change) play arrives without startAtMs;
        // apply forwards nil for scheduledAt.
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 9_000_000_000_000,
            videoId: "v", t: 10.0, playing: true,
            clientMs: nowMs - 50
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertNil(r.appliesScheduledAt[0])
    }

    func testScheduledTrackChangeHonorsClockOffset() {
        // Peer 2s ahead; track-change startAtMs = nowMs + 2500 (host clock)
        // → localStartAt = nowMs + 500 in our clock frame.
        let r = Recorder()
        let e = makeEngine(recorder: r, clockOffsetMsFor: { _ in 2000 })
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 9_000_000_000_000,
            videoId: "v", t: 0.0, playing: true,
            clientMs: nowMs,
            startAtMs: nowMs + 2500
        )))
        XCTAssertEqual(r.applies.count, 1)
        let forwarded = r.appliesScheduledAt[0]!
        XCTAssertTrue(abs(forwarded - (nowMs + 500)) <= 50,
            "forwarded startAtMs in local clock frame, got \(forwarded)")
    }
}
