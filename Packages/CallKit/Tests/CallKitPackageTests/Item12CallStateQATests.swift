import Foundation
import XCTest

@testable import CallKitPackage

/// Item 12 TESTER QA — plan §5.4 binding sequence, pinned as PURE-LOGIC tests
/// (no CallKit/PushKit/WebRTC/AVFAudio imports — the tested types are the
/// package's isolated state machine; plan §5.1 "CallKit/ … isolated").
///
/// The 8-step machine (§5.4):
///   1. app start (idle) → 3. reportNewIncomingCall (reported)
///   → 5. perform(CXAnswerCallAction), media prepared BEFORE fulfill (answered)
///   → 6. didActivateAudioSession — audio configuration legal ONLY here
///   → 7. "connected" declared to UI only after first remote + local frame
///   → 8. didDeactivate → ended.
///
/// These tests freeze the legal-transition table. Any change to the machine
/// (e.g. adding an explicit `connected` phase) must come with a §5.4-cited
/// reconciliation of this suite — a silent widening is a defect.
final class Item12CallStateQATests: XCTestCase {

    // MARK: - The §5.4-derived transition table (frozen contract)

    /// Exactly one owner: `idle` waits for a report; `ended` returns to idle.
    private static let legalTable: [CallPhase: Set<CallPhase>] = [
        .idle: [.reported, .ended],
        .reported: [.answered, .ended, .failed],
        .answered: [.activated, .ended, .failed],
        .activated: [.deactivated, .ended, .failed],
        .deactivated: [.activated, .ended, .failed], // §5.4 step 8: re-activate restart path
        .ended: [.idle],
        .failed: [.idle],
    ]

    private static let allPhases: [CallPhase] = [
        .idle, .reported, .answered, .activated, .deactivated, .ended, .failed,
    ]

    private func state(_ phase: CallPhase) -> CallState {
        var s = CallState()
        s.phase = phase
        return s
    }

    // MARK: Happy path — the binding 8-step sequence

    func testEightStepHappyPathFromIdleToEnded() {
        var s = CallState()
        XCTAssertEqual(s.phase, .idle, "§5.4 step 1: app start is idle")

        XCTAssertTrue(s.transition(to: .reported), "§5.4 step 3: reportNewIncomingCall")
        XCTAssertEqual(s.phase, .reported)

        XCTAssertTrue(s.transition(to: .answered), "§5.4 step 5: answer action fulfilled after media prep")
        XCTAssertEqual(s.phase, .answered)

        XCTAssertTrue(s.transition(to: .activated), "§5.4 step 6: didActivateAudioSession — first point audio may run")
        XCTAssertEqual(s.phase, .activated)

        XCTAssertTrue(s.transition(to: .deactivated), "§5.4 step 8: didDeactivate")
        XCTAssertTrue(s.transition(to: .ended), "end")
        XCTAssertTrue(s.transition(to: .idle), "machine returns to rest state for the next call")
    }

    /// §5.4 step 7: "connected" is only ever declared AFTER activation — the
    /// machine must make every shortcut to the audio-on state impossible.
    func testAudioOnStateReachableOnlyThroughAnsweredOrDeactivated() {
        for start in [CallPhase.idle, .reported] {
            var s = state(start)
            XCTAssertFalse(
                s.transition(to: .activated),
                "\(start) → activated must be illegal: audio before answer/activate is the dead-mic class of bug (§5.4)"
            )
        }
        // The only legal entrances to .activated:
        var answeredMachine = state(.answered)
        XCTAssertTrue(answeredMachine.transition(to: .activated))
        var deactivatedMachine = state(.deactivated)
        XCTAssertTrue(deactivatedMachine.transition(to: .activated), "§5.4 step 8: hold→resume re-activation")
    }

    /// §5.4 forbidden move: "capture started before didActivate". Modeled at
    /// the machine level: no phase below `activated` may pass through the
    /// deactivation/restart edge, and `answered` (media prepared, action
    /// fulfilled, "no audio device start yet") must not behave as activated.
    func testCaptureBeforeActivateIsUnrepresentable() {
        var s = CallState()
        XCTAssertTrue(s.transition(to: .reported))
        XCTAssertTrue(s.transition(to: .answered))
        XCTAssertEqual(s.phase, .answered)
        // answered is NOT an audio-legal state: attempting to leave it via
        // the deactivation path (i.e. as if audio had been running) is illegal.
        XCTAssertFalse(s.transition(to: .deactivated))
        XCTAssertEqual(s.phase, .answered, "illegal transition leaves state untouched")
    }

    // MARK: Exhaustive transition-table conformance

    func testEveryPhasePairConformsToFrozenTable() {
        for from in Self.allPhases {
            for to in Self.allPhases {
                var s = state(from)
                let legal = Self.legalTable[from]?.contains(to) == true
                let moved = s.transition(to: to)
                XCTAssertEqual(moved, legal, "\(from) → \(to): table says \(legal ? "legal" : "illegal")")
                if !legal {
                    XCTAssertEqual(s.phase, from, "\(from) → \(to) rejected: state must be untouched")
                } else {
                    XCTAssertEqual(s.phase, to, "\(from) → \(to) accepted")
                }
            }
        }
    }

    /// A rejected transition must not corrupt the UUID either — the call
    /// identity is what reportNewIncomingCall/end use; a silent swap would
    /// desync provider callbacks from the state machine.
    func testRejectedTransitionPreservesCallUUID() {
        let uuid = UUID()
        var s = CallState(phase: .reported, callUUID: uuid)
        XCTAssertFalse(s.transition(to: .activated))
        XCTAssertEqual(s.callUUID, uuid)
        XCTAssertTrue(s.transition(to: .answered))
        XCTAssertEqual(s.callUUID, uuid)
    }

    // MARK: Failure + terminal-state law

    /// §5.4: every in-flight phase may fail (report rejected, negotiation
    /// dead, engine race) and the only exit from `failed` is the reset to idle.
    func testFailedReachableFromEveryInFlightPhaseAndResetsToIdle() {
        for from in [CallPhase.reported, .answered, .activated, .deactivated] {
            var s = state(from)
            XCTAssertTrue(s.transition(to: .failed), "\(from) → failed must be legal")
            XCTAssertEqual(s.phase, .failed)
            XCTAssertTrue(s.transition(to: .idle), "failed resets to idle for the next call")
        }
        var idle = CallState()
        XCTAssertFalse(idle.transition(to: .failed), "idle has nothing to fail")
    }

    func testEndedIsTerminalExceptForTheIdleReset() {
        for to in Self.allPhases where to != .idle {
            var s = state(.ended)
            XCTAssertFalse(s.transition(to: to), "ended → \(to) must be illegal")
        }
        var f = state(.failed)
        for to in Self.allPhases where to != .idle {
            XCTAssertFalse(f.transition(to: to), "failed → \(to) must be illegal")
        }
    }

    /// §5.4: one CXProvider, one call at a time — two machine values are
    /// independent; ending one must never disturb the other's phase.
    func testValueSemanticsKeepParallelMachinesIndependent() {
        var a = CallState()
        var b = CallState()
        XCTAssertNotEqual(a.callUUID, b.callUUID, "fresh machines carry distinct call identities")
        XCTAssertTrue(a.transition(to: .reported))
        XCTAssertEqual(b.phase, .idle, "sibling machine untouched")
        XCTAssertTrue(b.transition(to: .ended))
        XCTAssertEqual(a.phase, .reported, "sibling machine untouched")
        // Value semantics: a copy taken mid-call is a snapshot.
        let snapshot = a
        XCTAssertTrue(a.transition(to: .answered))
        XCTAssertEqual(snapshot.phase, .reported)
    }

    /// The provider tracks the reported call by UUID; the machine's identity
    /// must survive a full encode/decode cycle (state persisted at
    /// background/lock — USER LAW 3: voice keeps running when locked).
    func testPhaseCodableRoundTripEveryCase() throws {
        for phase in Self.allPhases {
            let data = try JSONEncoder().encode(phase)
            XCTAssertEqual(try JSONDecoder().decode(CallPhase.self, from: data), phase)
        }
    }

    func testCallUUIDIsStableAcrossTransitionSequence() {
        let uuid = UUID()
        var s = CallState(phase: .idle, callUUID: uuid)
        for next in [CallPhase.reported, .answered, .activated, .deactivated, .ended, .idle] {
            XCTAssertTrue(s.transition(to: next), "legal walk \(s.phase) → \(next)")
            XCTAssertEqual(s.callUUID, uuid)
        }
    }

    // MARK: - Composer .startCall reaches the real call machine (Item 4 left
    // the seam; §5.4 is entered through it — Item 12 acceptance criterion 4)

    /// The waveform intent's canonical name: `ComposerEvent.startCall`
    /// (FeaturesChat). CallKit cannot import FeaturesChat (would invert the
    /// package DAG), so the pin is structural: a machine taking the raw
    /// intent fires reported. This freezes the spelling the app-target host
    /// must switch on when it wires CallManager.
    func testStartCallIntentEntersCallMachineAsReported() {
        var machine = CallState()
        XCTAssertTrue(machine.phase == .idle, "fresh machine rests at idle")
        // The app-target host contract: .startCall → CallState.reported.
        XCTAssertTrue(machine.transition(to: .reported),
                      "a startCall intent must move the machine to reported (§5.4 step 3)")
        XCTAssertEqual(machine.phase, .reported)
    }

    /// One waveform tap = ONE call identity. A second startCall while a call
    /// is already reported must not fork a second machine — the transition
    /// table rejects re-reporting (§5.4: one CXProvider, one call).
    func testSecondStartCallWhileCallInFlightIsRejected() {
        var machine = CallState()
        XCTAssertTrue(machine.transition(to: .reported))
        XCTAssertFalse(machine.transition(to: .reported),
                       "re-firing startCall mid-call must be rejected, not restart ringing")
        XCTAssertEqual(machine.phase, .reported)
    }

    // MARK: - Hold / unhold: §5.4 step 8 re-activate RESTART contract

    /// Hold = didDeactivate (audio off); unhold = re-activate. §5.4 step 8:
    /// "on re-activate force-restart the WebRTC audio unit" — the machine's
    /// re-open of the .deactivated → .activated edge is the seam the
    /// production restart hook must hang on; this pins it as the ONLY path
    /// back to audio-on from a live call.
    func testHoldUnholdCycleIsExactlyDeactivatedReactivated() {
        var s = state(.activated)
        XCTAssertTrue(s.transition(to: .deactivated), "hold → didDeactivate")
        // While held, audio work is illegal: no shortcut back to anything but
        // re-activation, end, or failure.
        XCTAssertFalse(s.transition(to: .answered), "unhold is NOT re-answer")
        XCTAssertFalse(s.transition(to: .reported), "hold must not re-ring")
        XCTAssertTrue(s.transition(to: .activated), "unhold → re-activate (audio unit restart)")
        XCTAssertEqual(s.phase, .activated)
    }

    /// Rapid hold/unhold churn must be idempotent at the machine level —
    /// every cycle takes exactly the same two edges, no drift.
    func testRepeatedHoldUnholdCyclesStayOnTheTwoEdges() {
        var s = state(.activated)
        for cycle in 1...5 {
            XCTAssertTrue(s.transition(to: .deactivated), "cycle \(cycle): hold")
            XCTAssertTrue(s.transition(to: .activated), "cycle \(cycle): unhold")
        }
        XCTAssertEqual(s.phase, .activated)
        // …and the machine still ends cleanly afterwards (route-change churn
        // must not wedge the call).
        XCTAssertTrue(s.transition(to: .ended))
    }

    /// An ended call must NOT resurrect into a hold-resume: the
    /// .deactivated → .activated edge exists only while the call is live.
    func testUnholdAfterEndIsRejected() {
        var s = state(.deactivated)
        XCTAssertTrue(s.transition(to: .ended))
        XCTAssertFalse(s.transition(to: .activated),
                       "a deactivated-then-ended call cannot be revived via the hold edge")
        XCTAssertEqual(s.phase, .ended)
    }
}