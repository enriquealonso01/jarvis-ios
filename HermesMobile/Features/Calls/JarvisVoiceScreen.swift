import SwiftUI

/// Presents the voice screen from anywhere (a chat's voice button, Calls, the in-call pill).
@MainActor
final class JarvisVoicePresenter: ObservableObject {
    static let shared = JarvisVoicePresenter()
    @Published var isPresented = false

    /// Opens the voice screen and, when no call is live, starts one. The conversation is a
    /// CallKit call (`CallManager.placeDirectCall`), so it keeps going with the screen locked.
    func startConversation() {
        isPresented = true
        guard CallManager.shared.activeCallUUID == nil else { return }
        Task { await CallManager.shared.placeDirectCall() }
    }

    func reopen() { isPresented = true }
}

/// Maps the call's real state string (CallManager.callState) to what the screen shows. Ported
/// from v2's M2CallStateMapper: nothing here is driven by a timer.
enum JarvisVoicePhase: Equatable {
    case ready, connecting, listening, thinking, speaking, failed(String)

    static func from(callState: String, hasActiveCall: Bool) -> JarvisVoicePhase {
        switch callState {
        case "dialing", "ringing", "connecting": return .connecting
        case "active": return .listening
        default:
            if callState.hasPrefix("active · speaking") { return .speaking }
            if callState.hasPrefix("active ·") { return .thinking }
            if callState.hasPrefix("failed") { return .failed(callState) }
            return hasActiveCall ? .connecting : .ready
        }
    }

    var isLive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking: return true
        case .ready, .failed: return false
        }
    }

    var orbital: OrbitalState {
        switch self {
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .responding
        case .ready, .connecting, .failed: return .idle
        }
    }
}

/// The ChatGPT-style voice conversation (requirement 4), ported from v2's V2VoiceScreen with
/// the Orbital Core mark. Closing it leaves the call running; the in-call pill brings it back.
struct JarvisVoiceScreen: View {
    @ObservedObject private var manager = CallManager.shared
    @Environment(\.dismiss) private var dismiss

    private var phase: JarvisVoicePhase {
        JarvisVoicePhase.from(callState: manager.callState, hasActiveCall: manager.activeCallUUID != nil)
    }

    private var muted: Bool { manager.isMuted && phase.isLive }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "JARVIS")
                    .font(.caption.weight(.heavy))
                    .tracking(2)
                    .foregroundStyle(JarvisBrand.iceCore)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(JarvisBrand.iceCore)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(phase.isLive ? "Back to the app, the call continues" : "Close voice")
                .accessibilityIdentifier("voice.closeButton")
            }
            Spacer(minLength: 12)
            JarvisAuraView(phase: muted ? .ready : phase, volume: muted ? 0 : manager.remoteAudioLevel)
                .frame(width: 260, height: 260)
                .opacity(muted ? 0.55 : 1)
                .accessibilityIdentifier("voice.orbital")
            Text(verbatim: title)
                .font(.title2.weight(.bold))
                .foregroundStyle(JarvisBrand.iceCore)
                .padding(.top, 28)
                .accessibilityIdentifier("voice.status")
            Text(verbatim: detail)
                .font(.footnote)
                .foregroundStyle(JarvisBrand.metallicGray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 8)
                .lineLimit(6)
            Spacer(minLength: 12)
            controls
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JarvisBrand.obsidian.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.screen")
    }

    private var title: String {
        if muted { return String(localized: "Microphone muted") }
        switch phase {
        case .ready: return String(localized: "Ready to talk")
        case .connecting: return String(localized: "Connecting…")
        case .listening: return String(localized: "Listening")
        case .thinking: return String(localized: "Thinking…")
        case .speaking: return String(localized: "Speaking")
        case .failed: return String(localized: "Voice unavailable")
        }
    }

    private var detail: String {
        if muted { return String(localized: "JARVIS can't hear you until you unmute.") }
        switch phase {
        case .ready:
            return String(localized: "Talk to JARVIS like a phone call. It keeps going when you lock the phone.")
        case .connecting: return String(localized: "Opening a secure voice line.")
        case .listening: return manager.lastTranscript ?? String(localized: "Go ahead, JARVIS is listening.")
        case .thinking: return String(localized: "Working on it.")
        case .speaking: return manager.lastTranscript ?? String(localized: "JARVIS is answering.")
        case .failed(let reason):
            let why = reason.replacingOccurrences(of: "failed:", with: "").trimmingCharacters(in: .whitespaces)
            return why.isEmpty ? String(localized: "The voice line couldn't connect. Try again.") : why
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            roundButton(systemImage: muted ? "mic.slash.fill" : "mic.fill", fill: JarvisBrand.deepSurface,
                        label: muted ? "Unmute" : "Mute", id: "voice.muteButton") {
                manager.toggleMuteFromInChat()
            }
            .disabled(!phase.isLive)
            .opacity(phase.isLive ? 1 : 0.4)

            roundButton(systemImage: manager.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.wave.1.fill",
                        fill: JarvisBrand.deepSurface, label: manager.isSpeakerOn ? "Speaker off" : "Speaker on",
                        id: "voice.speakerButton") {
                manager.setSpeaker(!manager.isSpeakerOn)
            }
            .disabled(!phase.isLive)
            .opacity(phase.isLive ? 1 : 0.4)

            if phase.isLive {
                roundButton(systemImage: "phone.down.fill", fill: .red, label: "End call", id: "voice.endButton") {
                    manager.endActiveCall()
                    dismiss()
                }
            } else {
                roundButton(systemImage: "phone.fill", fill: JarvisBrand.jarvisCyan,
                            label: phase == .ready ? "Start" : "Try again", id: "voice.startButton") {
                    Task { await manager.placeDirectCall() }
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func roundButton(systemImage: String, fill: Color, label: LocalizedStringKey, id: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(fill == JarvisBrand.jarvisCyan ? JarvisBrand.obsidian : JarvisBrand.iceCore)
                .frame(width: 64, height: 64)
                .background(Circle().fill(fill))
                .overlay(Circle().stroke(JarvisBrand.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// While a call is live and the voice screen is closed: a compact pill at the top of the app
/// that shows the call's state and reopens the screen.
struct JarvisInCallPill: View {
    @ObservedObject private var manager = CallManager.shared
    @ObservedObject private var presenter = JarvisVoicePresenter.shared

    var body: some View {
        if manager.activeCallUUID != nil, !presenter.isPresented {
            let phase = JarvisVoicePhase.from(callState: manager.callState, hasActiveCall: true)
            HStack(spacing: 10) {
                OrbitalCoreView(state: phase.orbital, isStatic: true)
                    .frame(width: 28, height: 28)
                Text("JARVIS call")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(JarvisBrand.iceCore)
                Spacer(minLength: 4)
                Button {
                    manager.endActiveCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(.red))
                }
                .accessibilityLabel("End call")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(JarvisBrand.deepSurface))
            .overlay(Capsule().stroke(JarvisBrand.jarvisCyan.opacity(0.5), lineWidth: 1))
            .padding(.horizontal, 24)
            .contentShape(Capsule())
            .onTapGesture { presenter.reopen() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voice.inCallPill")
        }
    }
}
