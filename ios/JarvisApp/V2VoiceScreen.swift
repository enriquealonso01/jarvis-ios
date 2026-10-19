import SwiftUI
import DesignSystem
import FeaturesVoice

// MARK: - Voice screen (UI expansion 03 "Voice overlay" + reference/mobile-voice.png)
//
// The composer's voice button opens this overlay in an honest READY state —
// nothing is recorded until the user taps Start (03 V01: never imply
// recording before the session really starts). Every visual below is a pure
// function of the REAL CallManager state (`callState` → M2CallStateMapper):
// no timers fabricate listening/thinking/speaking. The centre is the approved
// Orbital Core mark (kit geometry, `OrbitalCoreView`), which already collapses
// to the static mark under Reduce Motion. Closing the overlay returns to the
// same chat; a live call keeps running behind the in-chat voice pill.

/// App-wide presenter for the voice overlay (the composer intent lands here).
@MainActor
final class V2VoiceOverlay: ObservableObject {
    static let shared = V2VoiceOverlay()
    @Published var isPresented = false

    func present() {
        isPresented = true
    }
}

/// UI state the screen renders, derived from the real call state.
enum V2VoicePhase: Equatable {
    case ready
    case connecting
    case listening
    case thinking
    case speaking
    case failed(String)

    static func from(callState: String, hasActiveCall: Bool) -> V2VoicePhase {
        switch M2CallStateMapper.docState(callState: callState) {
        case .connecting, .requestingPermission: return .connecting
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .failed: return .failed(callState)
        case .idle, .ended: return hasActiveCall ? .connecting : .ready
        }
    }

    var isLive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking: return true
        case .ready, .failed: return false
        }
    }
}

struct V2VoiceScreen: View {
    @ObservedObject private var mgr = CallManager.shared
    @Environment(\.dismiss) private var dismiss
    /// Local mirror of the call's mute toggle (reset whenever the call ends —
    /// a new call never starts muted, same rule CallManager applies).
    @State private var muted = false

    private var phase: V2VoicePhase {
        V2VoicePhase.from(callState: mgr.callState, hasActiveCall: mgr.activeCallUUID != nil)
    }

    private var orbitalState: OrbitalState {
        if muted { return .idle }
        return M2CallStateMapper.orbitalState(callState: mgr.callState)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            centre
            Spacer(minLength: 12)
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Tokens.Palette.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Tokens.Palette.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Tokens.Palette.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: mgr.activeCallUUID) { _, newValue in
            if newValue == nil { muted = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.screen")
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("JARVIS")
                    .font(.caption.weight(.heavy))
                    .tracking(1.8)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                Text(phase.isLive ? "Voice · this chat" : "Voice")
                    .font(.caption2)
                    .foregroundStyle(Tokens.Palette.textMuted)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(JarvisIconButtonStyle())
            .accessibilityLabel(phase.isLive ? "Back to chat (voice continues)" : "Close voice")
            .accessibilityIdentifier("voice.closeButton")
        }
    }

    // MARK: Centre (Orbital Core + status)

    private var centre: some View {
        VStack(spacing: 0) {
            OrbitalCoreView(state: orbitalState, isStatic: muted)
                .frame(width: 200, height: 200)
                .saturation(muted ? 0 : 1)
                .opacity(muted ? 0.55 : 1)
                .animation(.easeInOut(duration: 0.25), value: muted)
                .accessibilityIdentifier("voice.orbital")
            Text(statusTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 30)
                .accessibilityIdentifier("voice.status")
            Text(statusDetail)
                .font(.footnote)
                .foregroundStyle(Tokens.Palette.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 300)
                .padding(.top, 8)
                .accessibilityIdentifier("voice.detail")
        }
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        if muted && phase.isLive { return "Microphone muted" }
        switch phase {
        case .ready: return "Ready to speak"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .failed: return "Voice unavailable"
        }
    }

    private var statusDetail: String {
        if muted && phase.isLive { return "JARVIS can't hear you until you unmute." }
        switch phase {
        case .ready:
            return "Start a voice session with JARVIS. Nothing is recorded until you start, and the transcript is saved to this chat."
        case .connecting:
            return "Opening a secure voice line."
        case .listening:
            return "Go ahead — JARVIS is listening."
        case .thinking:
            return "Working on it."
        case .speaking:
            if let line = mgr.lastTranscript, !line.isEmpty { return line }
            return "JARVIS is answering."
        case .failed(let reason):
            let detail = reason.replacingOccurrences(of: "failed", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " :·-"))
            return detail.isEmpty
                ? "The voice line couldn't connect. Try again, or keep typing in the chat."
                : "\(detail). Try again, or keep typing in the chat."
        }
    }

    // MARK: Controls (mute · primary · end)

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                guard phase.isLive else { return }
                mgr.toggleMuteFromInChat()
                muted.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(muted ? Tokens.Palette.selected : Tokens.Palette.raised))
                    .overlay(Circle().strokeBorder(Tokens.Palette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!phase.isLive)
            .opacity(phase.isLive ? 1 : 0.45)
            .accessibilityLabel(muted ? "Unmute microphone" : "Mute microphone")
            .accessibilityIdentifier("voice.muteButton")

            Button {
                primaryTapped()
            } label: {
                Text(primaryLabel)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(phase.isLive ? Tokens.Palette.textPrimary : Tokens.Palette.onAccent)
                    .frame(minWidth: 160, minHeight: 56)
                    .padding(.horizontal, 8)
                    .background(
                        Capsule().fill(phase.isLive ? Tokens.Palette.raised : Tokens.Palette.accent))
                    .overlay(
                        Capsule().strokeBorder(phase.isLive ? Tokens.Palette.border : Color.clear,
                                               lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice.primaryButton")

            Button {
                if mgr.activeCallUUID != nil {
                    mgr.endActiveCall()
                    Haptics.tap()
                }
                dismiss()
            } label: {
                Image(systemName: phase.isLive ? "phone.down.fill" : "xmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Tokens.Palette.dangerFill))
                    .overlay(Circle().strokeBorder(Tokens.Palette.dangerBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(phase.isLive ? "End voice session" : "Close voice")
            .accessibilityIdentifier("voice.endButton")
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryLabel: String {
        switch phase {
        case .ready: return "Start voice"
        case .failed: return "Try again"
        default: return "Back to chat"
        }
    }

    private func primaryTapped() {
        if phase.isLive {
            // Voice keeps running; the in-chat pill takes over (03).
            dismiss()
        } else {
            Haptics.tap()
            Task { await mgr.placeDirectCall() }
        }
    }
}
