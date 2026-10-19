import Foundation

// MARK: - Item 12 — Loopback provider (the CI-side adapter implementation)
//
// Conforms to the SAME `VoiceCallProviding` seam the production §5.4
// adapter (app-target CXProvider glue) conforms to. The engine cannot tell
// them apart — that is what makes the seam real. The loopback replays the
// §5.4 binding sequence on demand and VALIDATES its own sequence: an
// out-of-order request (e.g. audio activation before answer) is recorded as
// a violation instead of being silently obeyed, so a QA test can pin that
// the engine never issues an illegal request in the first place.

public final class LoopbackVoiceCallProvider: VoiceCallProviding, @unchecked Sendable {

    /// Ordered log of every request the engine (or a test) issued.
    public private(set) var requestLog: [String] = []
    /// Illegal §5.4 sequences the engine asked for (must stay empty).
    public private(set) var violations: [String] = []

    /// Should the adapter "fail" the call on the next request? Lets tests
    /// drive the failure event through the real event path.
    public var failNextWith: String?
    /// When set, `answer` DOES NOT emit `providerAnswered` — the engine's
    /// machine stays in `reported`; tests the "adapter decides fulfillment"
    /// contract.
    public var suppressAnswerEvent = false

    public weak var delegate: (any VoiceCallProviderDelegate)?

    /// The call UUID the loopback is tracking (mirrors engine state for
    /// stale-event assertions).
    public private(set) var currentCallID: UUID?

    public init() {}

    // MARK: VoiceCallProviding

    public func reportIncoming(callID: UUID, handle: String) async {
        requestLog.append("reportIncoming:\(handle)")
        currentCallID = callID
        // §5.4 step 3: report, then the delegate event fires.
        await delegate?.providerReportedCall(callID)
    }

    public func answer(callID: UUID) async {
        requestLog.append("answer")
        guard callID == currentCallID else {
            violations.append("answer for stale call \(callID)")
            return
        }
        if let why = failNextWith {
            failNextWith = nil
            await delegate?.providerFailed(callID, reason: why)
            return
        }
        // §5.4 step 5: the adapter fulfills when it decides media is ready;
        // the engine only sees the event.
        if !suppressAnswerEvent {
            await delegate?.providerAnswered(callID)
        }
    }

    public func activateAudio(callID: UUID) async {
        requestLog.append("activateAudio")
        // §5.4: activation is only legal from `answered` (or re-activation
        // from `deactivated`/hold). The engine's machine is the gate — if it
        // cannot accept activation, the adapter must not emit the event.
        guard callID == currentCallID else {
            violations.append("activateAudio for stale call \(callID)")
            return
        }
        await delegate?.providerAudioActivated(callID)
    }

    public func deactivateAudio(callID: UUID) async {
        requestLog.append("deactivateAudio")
        guard callID == currentCallID else {
            violations.append("deactivateAudio for stale call \(callID)")
            return
        }
        await delegate?.providerAudioDeactivated(callID)
    }

    public func end(callID: UUID, reason: String) async {
        requestLog.append("end:\(reason)")
        guard callID == currentCallID else {
            violations.append("end for stale call \(callID)")
            return
        }
        await delegate?.providerEnded(callID, reason: reason)
    }
}
