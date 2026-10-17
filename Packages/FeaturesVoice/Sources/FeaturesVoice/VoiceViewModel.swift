import Foundation

/// FeaturesVoice stub (features #13–#20 land here from M2). Pure call
/// presentation state only — audio/CallKit/WebRTC live in the CallKit package
/// (plan §5.4 isolation). No UIKit/AVFAudio in this file, so tests run on Linux.
public enum VoicePresentation: Sendable, Equatable {
    /// Default: chat stays visible, compact mute/end pill (UI Law §7).
    case inChat
    /// Immersive CallKit UI: full-screen orb.
    case immersive
}

public struct VoiceSessionState: Sendable, Equatable {
    public var presentation: VoicePresentation
    public var isConnected: Bool
    public var isMuted: Bool

    public init(presentation: VoicePresentation = .inChat, isConnected: Bool = false, isMuted: Bool = false) {
        self.presentation = presentation
        self.isConnected = isConnected
        self.isMuted = isMuted
    }

    public mutating func connect() { isConnected = true }
    public mutating func disconnect() { isConnected = false; isMuted = false }
    public mutating func toggleMute() { isMuted.toggle() }
}
