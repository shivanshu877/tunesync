import XCTest
@testable import TuneSyncCore

final class SyncEngineTests: XCTestCase {

    final class Recorder {
        var broadcasts: [SyncMessage] = []
        var applies: [PlayerState] = []
        var appliesScheduledAt: [Int64?] = []
    }

    private func makeEngine(
        senderId: String = "self",
        recorder: Recorder
    ) -> SyncEngine {
        return SyncEngine(
            senderId: senderId,
            broadcast: { recorder.broadcasts.append($0) },
            applyState: { state, startAtMs in
                recorder.applies.append(state)
                recorder.appliesScheduledAt.append(startAtMs)
            }
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
        // 500ms network + 250ms apply overhead = ~750ms forward seek
        XCTAssertEqual(r.applies[0].t, 10.75, accuracy: 0.15)
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

    func testLatencyCompensationCappedAtCompCap() {
        // Defends against badly skewed Mac clocks: don't advance beyond compCap (1500ms).
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs - 60_000   // peer's clock claims 60s in the past
        )))
        XCTAssertEqual(r.applies.count, 1)
        // Capped at 1.5s (compCapMs default). Anything beyond is treated as skew.
        XCTAssertEqual(r.applies[0].t, 11.5, accuracy: 0.05)
    }

    func testLatencyCompensationAppliesNetworkPlusApplyOverhead() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs - 100   // 100ms network — under cap, should comp
        )))
        XCTAssertEqual(r.applies.count, 1)
        // 100ms net + 250ms apply = ~350ms total
        XCTAssertEqual(r.applies[0].t, 10.35, accuracy: 0.10)
    }

    // MARK: - Scheduled play

    func testLocalPlayBroadcastIncludesStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        e.localStateChanged(PlayerState(videoId: "v", t: 0, playing: true))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNotNil(s.startAtMs)
        // 3-second schedule buffer (default), allow ±300ms scheduler jitter
        XCTAssertGreaterThanOrEqual(s.startAtMs!, before + 2700)
        XCTAssertLessThanOrEqual(s.startAtMs!, before + 3300)
    }

    func testLocalPauseBroadcastNoStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "v", t: 5, playing: false))
        e.flushDebounceForTesting()
        guard case .state(let s) = r.broadcasts.last else { return XCTFail("expected state") }
        XCTAssertNil(s.startAtMs, "pauses should propagate immediately, no schedule")
    }

    func testHostHeartbeatNoStartAtMs() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.role = .host
        e.localStateChanged(PlayerState(videoId: "v", t: 5, playing: true))
        e.flushDebounceForTesting()
        XCTAssertEqual(r.broadcasts.count, 1)
        XCTAssertNotNil(r.broadcasts[0].stateOrNil()?.startAtMs, "user-driven play scheduled")

        e.heartbeatTickForTesting()
        XCTAssertEqual(r.broadcasts.count, 2)
        XCTAssertNil(r.broadcasts[1].stateOrNil()?.startAtMs, "heartbeat is steady-state, never scheduled")
    }

    func testRemoteScheduledPlayIsForwardedToApply() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let scheduledAt = nowMs + 500
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "v", t: 10.0, playing: true,
            clientMs: nowMs - 100,
            startAtMs: scheduledAt
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.appliesScheduledAt[0], scheduledAt, "scheduled time forwarded to apply layer")
        // Latency comp NOT applied — schedule handles cross-Mac alignment
        XCTAssertEqual(r.applies[0].t, 10.0, accuracy: 0.001)
    }

    func testRemoteUnscheduledPlayStillUsesLatencyComp() {
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "v", t: 10.0, playing: true,
            clientMs: nowMs - 100   // 100ms ago
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertNil(r.appliesScheduledAt[0], "no schedule when message has no startAtMs")
        XCTAssertEqual(r.applies[0].t, 10.35, accuracy: 0.10, "100ms net + 250ms apply overhead")
    }

    func testLocalPlayAppliesItselfWithSchedule() {
        // The host's own click-play should also wait for the schedule
        // window so the host doesn't play 250ms ahead of every guest.
        let r = Recorder()
        let e = makeEngine(recorder: r)
        e.localStateChanged(PlayerState(videoId: "v", t: 0, playing: true))
        e.flushDebounceForTesting()
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertNotNil(r.appliesScheduledAt[0], "local play scheduled too")
    }

    // MARK: - Latency comp regression tests

    func testLatencyCompensationOnZeroNetworkAddsApplyOverhead() {
        // Even when network elapsed is 0 (best case), receiver should still
        // shift forward by applyOverheadMs to land on where host will be
        // when seek finishes.
        let r = Recorder()
        let e = makeEngine(recorder: r)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        e.handleRemote(.state(StateMessage(
            senderId: "peer", ts: 1000,
            videoId: "vid", t: 10.0, playing: true,
            clientMs: nowMs   // exactly now
        )))
        XCTAssertEqual(r.applies.count, 1)
        XCTAssertEqual(r.applies[0].t, 10.25, accuracy: 0.05)
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
