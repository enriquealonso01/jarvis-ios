import Foundation

/// CallKit package stub (plan §5.1/§5.4 — CallManager + AudioManager + WebRTC
/// glue land in M2). This file is pure call STATE MACHINE logic only: no
/// CallKit, PushKit, WebRTC, or AVFAudio imports, so `swift test` runs on Linux.
/// M2 makes audio APIs physically unreachable outside the `activated` state.
public enum CallPhase: String, Sendable, Equatable, Codable {
    case idle
    case reported      // reportNewIncomingCall done
    case answered      // CXAnswerCallAction performed, media preparing
    case activated     // didActivateAudioSession — only here may audio run
    case deactivated   // didDeactivateAudioSession
    case ended
    case failed
}

public struct CallState: Sendable, Equatable {
    public var phase: CallPhase
    public var callUUID: UUID

    public init(phase: CallPhase = .idle, callUUID: UUID = UUID()) {
        self.phase = phase
        self.callUUID = callUUID
    }

    /// Legal transitions per plan §5.4's 8-step machine. Illegal transitions
    /// return false and leave state untouched (unit-tested).
    public mutating func transition(to next: CallPhase) -> Bool {
        let legal: [CallPhase: Set<CallPhase>] = [
            .idle: [.reported, .ended],
            .reported: [.answered, .ended, .failed],
            .answered: [.activated, .ended, .failed],
            .activated: [.deactivated, .ended, .failed],
            .deactivated: [.activated, .ended, .failed], // hold/unhold restart path
            .ended: [.idle],
            .failed: [.idle],
        ]
        guard legal[phase]?.contains(next) == true else { return false }
        phase = next
        return true
    }
}
