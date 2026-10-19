import Foundation

// MARK: - Item 12 (Voice M2) — the real provider seam + call engine
//
// Plan §5.4 wires CallKit/WebRTC through ONE binding sequence. The engine
// below is its package-level core: the existing pure `CallState` machine is
// the only writer of call phase, and EVERY mutation arrives as a REAL
// provider event (§5.4 steps 3/5/6/8) — the engine has no timers and can
// never fabricate a phase (kit spec: "states driven by REAL events").
//
// `VoiceCallProviding` is the real adapter seam: the production adapter
// (app target, §5.4 CXProvider/CXAnswerCallAction/didActivateAudioSession)
// conforms to it; the loopback instance conforms to the SAME protocol and
// replays the binding sequence for CI — the engine cannot tell the
// difference, which is exactly what makes the seam real.

/// User-facing call phase — the projection the voice layer/UI consumes.
/// Distinct from `CallPhase` (the §5.4 machine states): this is what a human
/// sees, including §5.4 step 7 ("connected" declared only after first remote
/// + first local frame verified).
public enum VoiceCallPhase: String, Sendable, Equatable, CaseIterable {
    /// §5.4 step 1: app start — no call.
    case idle
    /// Reported to CallKit; ringing (incoming §5.4 step 3 or outgoing start).
    case ringing
    /// Answer action in flight; media not yet verified (step 5 → 7 gap).
    case connecting
    /// Step 7: audio live AND first remote frame + first local frame verified.
    case connected
    case ended
    case failed
}

/// The REAL provider adapter seam (plan §5.4). One implementation per
/// transport; the engine is transport-agnostic by construction.
///
/// Conformance contract (pinned by Item12VoiceCallEngineQATests):
///   • `reportIncoming` must produce exactly one `providerReportedCall`
///     (§5.4 step 3, reported on the same runloop — the real adapter hops
///     through its own main-thread queue, the loopback is synchronous).
///   • `answer` fulfills only AFTER media is prepared (step 5) — the
///     adapter decides when; the engine only ever sees the event.
///   • `activateAudio`/`deactivateAudio` bracket the audio window
///     (didActivate/didDeactivate, steps 6/8) and MUST fire the matching
///     delegate events; audio APIs are physically unreachable outside them.
public protocol VoiceCallProviding: AnyObject, Sendable {
    /// §5.4: one delegate — the engine that owns the machine.
    var delegate: (any VoiceCallProviderDelegate)? { get set }

    func reportIncoming(callID: UUID, handle: String) async
    func answer(callID: UUID) async
    func activateAudio(callID: UUID) async
    func deactivateAudio(callID: UUID) async
    /// §5.4 step 8 terminal: end/hold-never-resumes. `reason` is telemetry.
    func end(callID: UUID, reason: String) async
}

/// Provider → engine events. Every machine transition originates here —
/// the engine exposes NO method that mutates phase directly.
public protocol VoiceCallProviderDelegate: AnyObject, Sendable {
    func providerReportedCall(_ callID: UUID) async
    func providerAnswered(_ callID: UUID) async
    func providerAudioActivated(_ callID: UUID) async
    func providerAudioDeactivated(_ callID: UUID) async
    func providerEnded(_ callID: UUID, reason: String) async
    func providerFailed(_ callID: UUID, reason: String) async
}

// MARK: - Engine

/// Owns one `CallState` machine and maps provider events onto it.
///
/// Laws encoded here (each pinned by a QA test):
///   1. Illegal provider events are DROPPED, never crash, never corrupt
///      state (the machine rejects and leaves phase untouched) — and the
///      drop is COUNTED so a misbehaving adapter is visible in telemetry.
///   2. Events for a stale call UUID are ignored (§5.4 dedupe: the provider
///      tracks calls by UUID; a late event from an ended call must not
///      move the next call's machine).
///   3. §5.4 step 7: `.connected` requires activation AND first remote frame
///      AND first local capture frame — a verified-media watchdog in the
///      engine itself, not the UI's optimism.
///   4. `.connected`/phase projection is a pure function of (machine phase,
///      frame flags) — recomputed, never stored twice.
public actor VoiceCallEngine {

    /// The machine (value-type semantics preserved: snapshots are copies).
    public private(set) var state: CallState
    /// User-facing projection (derived).
    public private(set) var phase: VoiceCallPhase = .idle
    /// Mute pauses microphone sending; never moves the machine (UI Law §7).
    public private(set) var isMuted = false
    /// §5.4 step 7 frame watchdog flags.
    public private(set) var remoteFrameSeen = false
    public private(set) var localFrameSeen = false
    /// Telemetry: how many provider events the machine rejected/ignored.
    public private(set) var rejectedEventCount = 0
    /// Last rejected machine event (nil = a stale-UUID drop, not a table
    /// rejection — distinguishable in logs).
    public private(set) var lastRejectedPhase: CallPhase?
    /// Telemetry from terminal events.
    public private(set) var terminalReason: String?

    private let provider: any VoiceCallProviding

    public init(provider: any VoiceCallProviding) {
        self.state = CallState()
        self.provider = provider
        // The engine IS the delegate — events are the only mutation path.
        provider.delegate = self
    }

    // MARK: Host intents (the app target forwards these; no phase writes)

    /// Waveform intent (ComposerEvent.startCall) / incoming-report request.
    /// Reuses the engine after a terminal call: ended/failed REPLACES the
    /// machine with a fresh `CallState` (§5.4 calls are UUID-identified — a
    /// new call is a new identity), but never forks a second in-flight call.
    public func startCall(handle: String) async {
        if state.phase == .ended || state.phase == .failed {
            // Fresh machine = fresh callUUID for the next §5.4 call.
            state = CallState()
        }
        guard state.phase == .idle else {
            rejectedEventCount += 1
            return
        }
        remoteFrameSeen = false
        localFrameSeen = false
        terminalReason = nil
        await provider.reportIncoming(callID: state.callUUID, handle: handle)
    }

    /// §5.4 step 5: answer. The ADAPTER fulfills after media prep; the
    /// engine merely forwards the intent.
    public func answer() async {
        await provider.answer(callID: state.callUUID)
    }

    /// §5.4 step 6 boundary (didActivateAudioSession forward).
    public func activateAudio() async {
        await provider.activateAudio(callID: state.callUUID)
    }

    /// §5.4 step 8 boundary (didDeactivate — hold).
    public func deactivateAudio() async {
        await provider.deactivateAudio(callID: state.callUUID)
    }

    /// End intent (compact pill / immersive button, UI Law §7).
    public func endCall(reason: String) async {
        await provider.end(callID: state.callUUID, reason: reason)
    }

    /// Mute pauses mic sending (UI Law §7); phase never moves.
    public func toggleMute() {
        isMuted.toggle()
    }

    /// §5.4 step 7: first REMOTE audio frame verified.
    public func markRemoteFrameVerified() {
        remoteFrameSeen = true
        reproject()
    }

    /// §5.4 step 7: first LOCAL capture frame verified.
    public func markLocalFrameVerified() {
        localFrameSeen = true
        reproject()
    }

    /// Value-type snapshot for observers (SwiftUI host, tests).
    public func snapshot() -> VoiceCallSnapshot {
        VoiceCallSnapshot(
            phase: phase,
            machinePhase: state.phase,
            callUUID: state.callUUID,
            isMuted: isMuted,
            remoteFrameSeen: remoteFrameSeen,
            localFrameSeen: localFrameSeen,
            rejectedEventCount: rejectedEventCount,
            lastRejectedPhase: lastRejectedPhase,
            terminalReason: terminalReason)
    }

    // MARK: Event application (the ONLY mutation paths)

    private func apply(_ next: CallPhase) -> Bool {
        if state.transition(to: next) {
            if next == .ended {
                // Mute is per-call: ending clears it (next call starts unmuted).
                isMuted = false
            }
            reproject()
            return true
        }
        rejectedEventCount += 1
        lastRejectedPhase = next
        return false
    }

    private func reproject() {
        phase = VoiceCallEngine.project(
            machine: state.phase,
            remoteSeen: remoteFrameSeen,
            localSeen: localFrameSeen)
    }

    /// Pure mapping (unit-pinned exhaustively): machine → user phase.
    static func project(machine: CallPhase, remoteSeen: Bool, localSeen: Bool) -> VoiceCallPhase {
        switch machine {
        case .idle: return .idle
        case .reported: return .ringing
        case .answered: return .connecting
        case .activated, .deactivated:
            // Step 7: connected ONLY with both frames verified. Hold keeps
            // the connected projection — the call is live, audio is held.
            return (remoteSeen && localSeen) ? .connected : .connecting
        case .ended: return .ended
        case .failed: return .failed
        }
    }
}

// MARK: - Provider events (delegate conformance — real events only)

extension VoiceCallEngine: VoiceCallProviderDelegate {

    public func providerReportedCall(_ callID: UUID) async {
        guard callID == state.callUUID else { rejectedEventCount += 1; return }
        _ = apply(.reported) // §5.4 step 3
    }

    public func providerAnswered(_ callID: UUID) async {
        guard callID == state.callUUID else { rejectedEventCount += 1; return }
        _ = apply(.answered) // §5.4 step 5 (media prepared, fulfilled)
    }

    public func providerAudioActivated(_ callID: UUID) async {
        guard callID == state.callUUID else { rejectedEventCount += 1; return }
        _ = apply(.activated) // §5.4 step 6 — first point audio may run
    }

    public func providerAudioDeactivated(_ callID: UUID) async {
        guard callID == state.callUUID else { rejectedEventCount += 1; return }
        _ = apply(.deactivated) // §5.4 step 8 (hold)
    }

    public func providerEnded(_ callID: UUID, reason: String) async {
        guard callID == state.callUUID else { rejectedEventCount += 1; return }
        terminalReason = reason
        _ = apply(.ended)
    }

    public func providerFailed(_ callID: UUID, reason: String) async {
        guard callID == state.callUUID else { rejectedEventCount += 1; return }
        terminalReason = reason
        _ = apply(.failed)
    }
}

// MARK: - Snapshot

/// Sendable value snapshot of the engine at one instant.
public struct VoiceCallSnapshot: Sendable, Equatable {
    public let phase: VoiceCallPhase
    public let machinePhase: CallPhase
    public let callUUID: UUID
    public let isMuted: Bool
    public let remoteFrameSeen: Bool
    public let localFrameSeen: Bool
    public let rejectedEventCount: Int
    public let lastRejectedPhase: CallPhase?
    public let terminalReason: String?

    public init(phase: VoiceCallPhase, machinePhase: CallPhase, callUUID: UUID,
                isMuted: Bool, remoteFrameSeen: Bool, localFrameSeen: Bool,
                rejectedEventCount: Int, lastRejectedPhase: CallPhase?,
                terminalReason: String?) {
        self.phase = phase
        self.machinePhase = machinePhase
        self.callUUID = callUUID
        self.isMuted = isMuted
        self.remoteFrameSeen = remoteFrameSeen
        self.localFrameSeen = localFrameSeen
        self.rejectedEventCount = rejectedEventCount
        self.lastRejectedPhase = lastRejectedPhase
        self.terminalReason = terminalReason
    }
}
