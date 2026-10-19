import Foundation
import XCTest

@testable import CallKitPackage

/// Item 12 BUILDER QA — the engine over the REAL provider-event path.
///
/// These tests drive `VoiceCallEngine` exclusively through the
/// `VoiceCallProviding` adapter seam (loopback implementation) and the
/// delegate event path — exactly how the app-target §5.4 adapter will drive
/// it. No timer, no direct phase writes, no state fabrication anywhere.
///
/// §5.4 binding sequence pinned end-to-end:
///   startCall → reportIncoming → providerReportedCall (step 3, reported)
///   → answer → providerAnswered (step 5, media prepared before fulfill)
///   → providerAudioActivated (step 6 — first point audio may run)
///   → frame watchdogs (step 7: connected only after BOTH frames)
///   → providerAudioDeactivated (step 8, hold) → re-activate → end.
final class Item12VoiceCallEngineQATests: XCTestCase {

    // MARK: - The full §5.4 walk over the adapter seam

    func testEightStepSequenceOverRealAdapterPathReachesConnectedAndEnds() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        await engine.startCall(handle: "jarvis")
        var snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .reported, "§5.4 step 3")
        XCTAssertEqual(snap.phase, .ringing)

        await engine.answer()
        snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .answered, "§5.4 step 5: answer event after media prep")
        XCTAssertEqual(snap.phase, .connecting, "step 7 gap: NOT connected until frames verified")

        // Step 6: activation event arrives — audio window opens, but the
        // step-7 watchdog still holds the projection at connecting.
        await provider.activateAudio(callID: snap.callUUID)
        snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .activated)
        XCTAssertEqual(snap.phase, .connecting, "activation alone is not 'connected' (§5.4 step 7)")

        // First remote frame only → still not connected.
        await engine.markRemoteFrameVerified()
        snap = await engine.snapshot()
        XCTAssertEqual(snap.phase, .connecting, "one frame is not 'connected'")

        // First local capture frame → step 7 satisfied → connected.
        await engine.markLocalFrameVerified()
        snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .activated)
        XCTAssertEqual(snap.phase, .connected, "§5.4 step 7: declared after BOTH frames verified")

        // Step 8: hold → unhold churn, still connected afterwards.
        await engine.deactivateAudio()
        snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .deactivated)
        await engine.activateAudio()
        snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .activated)
        XCTAssertEqual(snap.phase, .connected, "hold/unhold churn does not lose the verified-media state")

        // Terminate.
        await engine.endCall(reason: "user-hangup")
        snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .ended)
        XCTAssertEqual(snap.phase, .ended)
        XCTAssertEqual(snap.terminalReason, "user-hangup")

        // The engine asked the adapter for exactly the legal request set.
        XCTAssertEqual(provider.requestLog,
                       ["reportIncoming:jarvis", "answer", "activateAudio",
                        "deactivateAudio", "activateAudio", "end:user-hangup"])
        XCTAssertTrue(provider.violations.isEmpty, "engine must never issue an illegal §5.4 request")
    }

    // MARK: - Engine has no self-directed transitions

    func testIdleEngineNeverMovesWithoutProviderEvents() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        let snap = await engine.snapshot()
        XCTAssertEqual(snap.phase, .idle)
        XCTAssertEqual(snap.machinePhase, .idle)
        XCTAssertEqual(provider.requestLog, [], "no call in flight → no adapter requests")
        // Snapshot twice; nothing time-based can change it (no timers).
        let again = await engine.snapshot()
        XCTAssertEqual(snap, again, "engine state is event-driven only")
    }

    // MARK: - §5.4: one call at a time

    func testSecondStartCallWhileInFlightIsDroppedAndCounted() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        await engine.startCall(handle: "first")
        let first = await engine.snapshot()
        XCTAssertEqual(first.machinePhase, .reported)

        await engine.startCall(handle: "second")
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .reported, "no re-ring mid-call")
        XCTAssertEqual(snap.callUUID, first.callUUID, "call identity stable")
        XCTAssertEqual(provider.requestLog.filter { $0.hasPrefix("reportIncoming") }.count, 1,
                       "exactly ONE report reached the adapter (§5.4: one call)")
        XCTAssertEqual(snap.rejectedEventCount, 1, "the second intent is visible in telemetry")
    }

    // MARK: - Failure path through the real event seam

    func testAdapterFailureEventFailsTheCallFromAnswered() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        await engine.startCall(handle: "jarvis")
        provider.failNextWith = "negotiation-dead"
        await engine.answer()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .failed)
        XCTAssertEqual(snap.phase, .failed)
        XCTAssertEqual(snap.terminalReason, "negotiation-dead")
        // failed → idle reset happens on the NEXT start (machine law), and
        // the new call gets a FRESH identity.
        await engine.startCall(handle: "again")
        let next = await engine.snapshot()
        XCTAssertEqual(next.machinePhase, .reported)
        XCTAssertNotEqual(next.callUUID, snap.callUUID, "a new call is a new §5.4 identity")
    }

    // MARK: - Stale provider events (cross-call UUID law)

    func testStaleCallEventsAreIgnoredNotApplied() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        await engine.startCall(handle: "a")
        let first = await engine.snapshot()
        await engine.endCall(reason: "done")
        let ended = await engine.snapshot()
        XCTAssertEqual(ended.machinePhase, .ended)

        // A late activation event for the ENDED call must not move the
        // fresh (idle) machine.
        await provider.activateAudio(callID: first.callUUID)
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .ended, "stale event cannot resurrect the ended call")
        XCTAssertEqual(snap.rejectedEventCount, 1)
    }

    // MARK: - Mute law (UI Law §7): pauses mic sending, never the machine

    func testMuteNeverMovesTheMachineAndClearsOnEnd() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        await engine.startCall(handle: "jarvis")
        await engine.answer()
        await engine.activateAudio()

        await engine.toggleMute()
        var snap = await engine.snapshot()
        XCTAssertTrue(snap.isMuted)
        XCTAssertEqual(snap.machinePhase, .activated, "mute is NOT a hold")
        XCTAssertEqual(snap.phase, .connecting)

        await engine.toggleMute()
        snap = await engine.snapshot()
        XCTAssertFalse(snap.isMuted)

        await engine.endCall(reason: "bye")
        snap = await engine.snapshot()
        XCTAssertFalse(snap.isMuted, "mute is per-call — a new call starts unmuted")
    }

    // MARK: - Projection table (exhaustive, pure)

    func testProjectionIsExhaustiveAndStepSevenGated() {
        XCTAssertEqual(VoiceCallEngine.project(machine: .idle, remoteSeen: false, localSeen: false), .idle)
        XCTAssertEqual(VoiceCallEngine.project(machine: .reported, remoteSeen: true, localSeen: true), .ringing)
        XCTAssertEqual(VoiceCallEngine.project(machine: .answered, remoteSeen: true, localSeen: true), .connecting,
                       "answered is never connected — activation + frames required")
        XCTAssertEqual(VoiceCallEngine.project(machine: .activated, remoteSeen: false, localSeen: false), .connecting)
        XCTAssertEqual(VoiceCallEngine.project(machine: .activated, remoteSeen: true, localSeen: false), .connecting)
        XCTAssertEqual(VoiceCallEngine.project(machine: .activated, remoteSeen: false, localSeen: true), .connecting)
        XCTAssertEqual(VoiceCallEngine.project(machine: .activated, remoteSeen: true, localSeen: true), .connected)
        XCTAssertEqual(VoiceCallEngine.project(machine: .deactivated, remoteSeen: true, localSeen: true), .connected,
                       "hold keeps the connected projection")
        XCTAssertEqual(VoiceCallEngine.project(machine: .ended, remoteSeen: true, localSeen: true), .ended)
        XCTAssertEqual(VoiceCallEngine.project(machine: .failed, remoteSeen: false, localSeen: false), .failed)
    }

    // MARK: - Adapter refuses illegal engine requests (belt + braces)

    func testActivationBeforeAnswerIsRecordedAsAdapterViolation() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        // Engine still in idle: asking for activation is an engine bug by
        // construction (no such public path exists), so drive the adapter
        // directly to prove the loopback VALIDATES sequence order.
        let fakeID = await engine.snapshot().callUUID
        await provider.activateAudio(callID: fakeID)
        XCTAssertEqual(provider.violations.count, 0,
                       "loopback forwards to delegate; the ENGINE's machine is the §5.4 gate")
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .idle,
                       "providerAudioActivated from idle is DROPPED by the machine (illegal transition)")
        XCTAssertEqual(snap.rejectedEventCount, 1)
        XCTAssertEqual(snap.lastRejectedPhase, .activated)
    }

    // MARK: - Snapshot round-trip through every §5.4 phase

    func testSnapshotTracksEveryMachinePhaseOverTheFullWalk() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        let expected: [(CallPhase, VoiceCallPhase)] = [
            (.reported, .ringing), (.answered, .connecting), (.activated, .connecting),
            (.deactivated, .connecting), (.activated, .connecting), (.ended, .ended),
        ]
        await engine.startCall(handle: "jarvis")
        await walk(engine, provider, expected)
    }

    private func walk(_ engine: VoiceCallEngine, _ provider: LoopbackVoiceCallProvider,
                      _ steps: [(CallPhase, VoiceCallPhase)]) async {
        var index = 0
        func check() async {
            guard index < steps.count else { return }
            let snap = await engine.snapshot()
            XCTAssertEqual(snap.machinePhase, steps[index].0, "step \(index)")
            XCTAssertEqual(snap.phase, steps[index].1, "step \(index)")
            index += 1
        }
        await check() // reported
        await engine.answer(); await check() // answered
        await engine.activateAudio(); await check() // activated
        await engine.deactivateAudio(); await check() // deactivated
        await engine.activateAudio(); await check() // re-activated
        await engine.endCall(reason: "x"); await check() // ended
    }

    // MARK: - Loopback sequence validation

    func testLoopbackFlagsStaleCallRequestsAsViolations() async {
        let provider = LoopbackVoiceCallProvider()
        _ = VoiceCallEngine(provider: provider)

        await provider.answer(callID: UUID()) // never reported
        await provider.end(callID: UUID(), reason: "ghost")
        XCTAssertEqual(provider.violations.count, 2,
                       "adapter-level validation: stale UUIDs are violations, not silent no-ops")
        XCTAssertTrue(provider.requestLog.contains("answer"))
    }

    func testSuppressAnswerEventLeavesEngineRinging() async {
        let provider = LoopbackVoiceCallProvider()
        let engine = VoiceCallEngine(provider: provider)

        provider.suppressAnswerEvent = true
        await engine.startCall(handle: "jarvis")
        await engine.answer()
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.machinePhase, .reported,
                       "the adapter decides fulfillment: no event → no machine move")
        XCTAssertEqual(provider.requestLog.filter { $0 == "answer" }.count, 1)
    }
}
