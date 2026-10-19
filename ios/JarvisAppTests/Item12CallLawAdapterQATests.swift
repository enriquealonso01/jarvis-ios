import XCTest

@testable import JarvisApp

/// Item 12 (Voice M2) — TESTER verification pins for the app-target call-law
/// adapter surface that no package-level suite reaches (the VoiceCallEngine
/// QA pins the machine over the loopback; THIS suite pins the REAL
/// CallManager push→CallKit entry guards that decide whether the phone
/// RINGS — USER LAW: "it must CALL his phone CORRECTLY", with zero slack):
///
///   • APNs is at-least-once: a re-delivered push for a call that already
///     ended must NEVER ring again (post-end redelivery guard).
///   • A re-delivery of the SAME call while it is live must reuse the SAME
///     UUID (no stacked second CallKit call, no lost log outcome).
///   • A DIFFERENT call while one is live is acknowledged + logged missed —
///     the live call is untouched (one call at a time).
///   • Direct outgoing calls carry NO `reason` (Pitfall M: a non-empty
///     reason makes the gateway inject the automated-call notice + end_call
///     — the call announces itself as a robot and hangs up).
///   • Terminal flush: ending while still ringing stamps "missed" (never a
///     zombie open entry) and clears the active call.
///
/// Headless-contract notes: with no CXProvider configured, the
/// reportNewIncomingCall calls no-op (optional chaining) but every guard,
/// log write, and state mutation still executes — the exact decision logic
/// under test. CallKit-side ordering laws (report-before-return from the
/// PushKit callback, fulfill-immediately answer) are static structure in
/// CallManager.swift and are attested in the Item 12 QA log, not here.
@MainActor
final class Item12CallLawAdapterQATests: XCTestCase {

    private var mgr: CallManager { CallManager.shared }

    private func countLogEntries(reason: String) -> Int {
        CallLogStore.shared.entries.filter { $0.reason == reason }.count
    }

    /// Unique per-test push payload so suites never share redelivery memory.
    private func pushPayload(callID: String, reason: String) -> [AnyHashable: Any] {
        ["reason": reason,
         "call_id": callID,
         "gateway_ws": "/voice-gw",
         "scheduled_by": "qa"]
    }

    override func setUp() {
        super.setUp()
        // Leave the shared manager idle no matter what a previous test did.
        mgr.endActiveCall()
    }

    override func tearDown() {
        mgr.endActiveCall()
        super.tearDown()
    }

    // MARK: - Post-end redelivery guard (APNs at-least-once)

    func testRedeliveredPushForEndedCallDoesNotRingAgainOrDoubleLog() {
        let callID = "qa-redelivery-\(UUID().uuidString.prefix(8))"
        let reason = "QA-ENDED-REDelivery-\(callID)"
        let before = countLogEntries(reason: reason)

        // 1st delivery: a fresh call — rings (active UUID assigned, logged).
        mgr.handleVoIPPayload(pushPayload(callID: callID, reason: reason))
        let firstUUID = mgr.activeCallUUID
        XCTAssertNotNil(firstUUID, "first delivery of a fresh call must ring")
        XCTAssertEqual(countLogEntries(reason: reason), before + 1,
                       "exactly one log entry for the first delivery")

        // End it: terminal flush + redelivery memory records the call_id.
        mgr.endActiveCall()
        XCTAssertNil(mgr.activeCallUUID)

        // 2nd delivery (the APNs retry arriving after the call ended):
        // must NOT ring (no active UUID) and must NOT add a second entry.
        mgr.handleVoIPPayload(pushPayload(callID: callID, reason: reason))
        XCTAssertNil(mgr.activeCallUUID,
                     "a push for an already-ended call must never ring again")
        XCTAssertEqual(countLogEntries(reason: reason), before + 1,
                       "the re-delivery must not log a phantom second call")
    }

    // MARK: - Same-call re-delivery while live

    func testSameCallRedeliveryWhileLiveReusesUUIDAndDoesNotStackALogEntry() {
        let callID = "qa-samecall-\(UUID().uuidString.prefix(8))"
        let reason = "QA-SAME-LIVE-\(callID)"
        let before = countLogEntries(reason: reason)

        mgr.handleVoIPPayload(pushPayload(callID: callID, reason: reason))
        let liveUUID = mgr.activeCallUUID
        XCTAssertNotNil(liveUUID)

        // Same call re-delivered while still ringing/active: same UUID (the
        // re-report goes out under the EXISTING call identity), no second
        // log entry, and the live call is not replaced.
        mgr.handleVoIPPayload(pushPayload(callID: callID, reason: reason))
        XCTAssertEqual(mgr.activeCallUUID, liveUUID,
                       "re-delivery of the live call must keep the same call identity")
        XCTAssertEqual(countLogEntries(reason: reason), before + 1,
                       "the live call's log entry must stay single")

        mgr.endActiveCall()
    }

    // MARK: - Second (different) call while one is live

    func testDifferentCallWhileLiveIsLoggedMissedAndNeverRings() {
        let liveID = "qa-live-\(UUID().uuidString.prefix(8))"
        let bumpID = "qa-bump-\(UUID().uuidString.prefix(8))"
        let liveReason = "QA-LIVE-\(liveID)"
        let bumpReason = "QA-BUMP-\(bumpID)"

        mgr.handleVoIPPayload(pushPayload(callID: liveID, reason: liveReason))
        let liveUUID = mgr.activeCallUUID
        XCTAssertNotNil(liveUUID)

        let missedBefore = countLogEntries(reason: bumpReason)
        mgr.handleVoIPPayload(pushPayload(callID: bumpID, reason: bumpReason))

        // The user's live call stays untouched...
        XCTAssertEqual(mgr.activeCallUUID, liveUUID,
                       "a second incoming call must not replace the live call")
        // ...the bump is acknowledged as missed exactly once...
        XCTAssertEqual(countLogEntries(reason: bumpReason), missedBefore + 1)
        XCTAssertEqual(CallLogStore.shared.entries.last { $0.reason == bumpReason }?.outcome,
                       "missed", "the bumped call is logged missed, never ringing")
        // ...and the manager did not adopt the bump's payload.
        XCTAssertNotEqual(mgr.pendingAnswerPayload?.callID, bumpID,
                          "the live call's answer payload must survive the bump")

        mgr.endActiveCall()
    }

    // MARK: - USER LAW: direct outgoing calls carry NO reason (Pitfall M)

    func testDirectOutgoingCallSendsNoReasonToTheGateway() async {
        // Idle manager (setUp). placeDirectCall adopts an outgoing payload
        // synchronously before the CXTransaction completes — the gateway
        // request body is built from these exact fields.
        await mgr.placeDirectCall()

        let payload = mgr.pendingAnswerPayload
        XCTAssertNotNil(payload, "placeDirectCall must adopt its outgoing payload")
        XCTAssertEqual(payload?.reason, "",
                       "direct app-initiated calls must send NO reason — a non-empty reason makes the gateway inject the automated-call notice + end_call (the call announces itself as a robot and hangs up)")
        XCTAssertEqual(payload?.scheduledBy, "ios-app-direct")
        XCTAssertEqual(payload?.gatewayWS, "/voice-gw")
        XCTAssertNotNil(mgr.activeCallUUID, "the direct call owns the live-call slot")

        mgr.endActiveCall()
    }

    // MARK: - Terminal flush

    func testEndingWhileRingingStampsMissedAndClearsState() {
        let callID = "qa-terminal-\(UUID().uuidString.prefix(8))"
        let reason = "QA-TERMINAL-\(callID)"

        mgr.handleVoIPPayload(pushPayload(callID: callID, reason: reason))
        XCTAssertEqual(mgr.callState, "ringing")

        mgr.endActiveCall()

        XCTAssertNil(mgr.activeCallUUID, "ending clears the live-call slot")
        XCTAssertEqual(mgr.callState, "idle", "state returns to idle")
        XCTAssertNil(mgr.pendingAnswerPayload, "the answer payload is released")
        let entry = CallLogStore.shared.entries.last { $0.reason == reason }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.outcome, "missed",
                       "a never-answered call is stamped missed — no zombie open entries")
        XCTAssertNil(mgr.lastTranscript, "call-scoped transcript state is flushed")
    }
}
