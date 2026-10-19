import SwiftUI

import DesignSystem

// MARK: - Item 12 (Voice M2) — in-chat voice layer surface (UI Law §7)
//
// Default presentation while a call is live: "chat stays visible, spoken
// answers stream as text, compact mute/end pill; user can scroll history
// and type back mid-call." The overlay is the compact pill; the transcript
// host owns chat visibility.

/// The compact mute/end pill for the in-chat voice layer.
struct V2InChatVoiceOverlay: View {
    /// Real call state (CallManager.callState) — drives the status line and
    /// the orbital via M2CallStateMapper (no hardcoded state).
    let callState: String
    /// Live call actions (CallManager). nil in previews/tests.
    var onToggleMute: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            VoiceOrbitalStatusView(state: M2CallStateMapper.orbitalState(callState: callState))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Text("JARVIS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: Tokens.Spacing.s) {
                Button {
                    onToggleMute?()
                } label: {
                    Image(systemName: "mic.slash")
                        .font(.body)
                        .frame(width: Tokens.Voice.pillHeight, height: Tokens.Voice.pillHeight)
                }
                .accessibilityLabel("Mute")
                Button {
                    onEnd?()
                    Haptics.tap()
                } label: {
                    Image(systemName: "end-call")
                        .font(.body)
                        .foregroundStyle(.red)
                        .frame(width: Tokens.Voice.pillHeight, height: Tokens.Voice.pillHeight)
                }
                .accessibilityLabel("End call")
            }
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .frame(maxWidth: .infinity)
        .frame(height: Tokens.Voice.pillHeight + Tokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Voice.pillCornerRadius)
                .fill(.regularMaterial)
        )
        .padding(.horizontal, Tokens.Voice.pillHorizontalInset)
    }

    private var statusLine: String {
        switch M2CallStateMapper.docState(callState: callState) {
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "JARVIS is speaking"
        case .failed: return "Call failed"
        default: return "Voice"
        }
    }
}
