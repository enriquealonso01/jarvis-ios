import Foundation
import UIKit
import SwiftUI

struct ComposerVoiceStatus: Equatable {
    let text: String
    let systemImage: String
    let isError: Bool
}

struct ComposerVoiceStatusView: View {
    let status: ComposerVoiceStatus

    var body: some View {
        Label(status.text, systemImage: status.systemImage)
            .font(.caption)
            .foregroundStyle(status.isError ? Color.red : Color.secondary)
    }
}

/// The composer mic (JARVIS requirement 12, Signal/WhatsApp): press and hold records at once,
/// swipe up while holding locks, slide left cancels, release sends, a quick tap records locked.
///
/// This view is only the mic's face and its VoiceOver actions. The touch itself is
/// `VoiceMicTouchHost` over the composer, because a SwiftUI gesture on this view would die the
/// moment the composer swaps to the recording bar, with the finger still down.
struct ComposerVoiceControlButton: View {
    let isListening: Bool
    let isDisabled: Bool
    let color: Color
    let isRecordingVoiceNote: Bool
    var supportsVoiceNotes = true
    /// A tap records a locked note (true) or toggles dictation (false).
    var tapRecords = true
    /// Dictation (tap with `tapRecords` off) and VoiceOver's default action.
    let onTap: () -> Void
    /// VoiceOver: start a locked note.
    let onVoiceOverRecord: () -> Void

    @ViewBuilder var body: some View {
        if supportsVoiceNotes {
            label
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    // VoiceOver synthesizes an activation rather than a real touch, so the
                    // touch host never sees it: start a locked note (or dictate).
                    guard !isDisabled, !isRecordingVoiceNote else { return }
                    if tapRecords { onVoiceOverRecord() } else { onTap() }
                }
                .accessibilityAction(named: Text("Record voice note")) {
                    guard !isDisabled, !isRecordingVoiceNote else { return }
                    onVoiceOverRecord()
                }
                .accessibilityIdentifier("composer.mic")
        } else {
            Button {
                onTap()
            } label: {
                label
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
    }

    private var label: some View {
        Image(systemName: symbolName)
            .font(.system(size: 18, weight: .regular))
            .frame(width: 44, height: 44)
            .foregroundStyle(isListening || isRecordingVoiceNote ? Color.red : color)
            .contentShape(Circle())
            .opacity(isDisabled && !isRecordingVoiceNote ? 0.4 : 1)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        if isRecordingVoiceNote { return "mic.fill" }
        return isListening ? "stop.circle.fill" : "mic"
    }

    private var accessibilityLabel: Text {
        Text(ComposerVoiceControlAccessibility.label(
            isListening: isListening,
            isRecordingVoiceNote: isRecordingVoiceNote
        ))
    }
}

enum ComposerVoiceControlAccessibility {
    static func label(isListening: Bool, isRecordingVoiceNote: Bool) -> String {
        if isRecordingVoiceNote { return String(localized: "Recording voice note") }
        return isListening ? String(localized: "Stop voice input") : String(localized: "Voice input")
    }
}

/// The live input level as a row of bars, newest on the right.
struct VoiceNoteWaveformView: View {
    let levels: [CGFloat]
    var color: Color = .red
    var barCount = 28

    var body: some View {
        let recent = Array(levels.suffix(barCount))
        let padded = Array(repeating: CGFloat(0), count: max(0, barCount - recent.count)) + recent
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: 2.5, height: max(3, 22 * level))
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

/// The recording bar: while a voice note is held, locked or paused the composer area is THIS and
/// nothing else (`if recording { VoiceNoteRecordingSurface } else { text bar }`), with an opaque
/// background and no glass: iOS draws a glass effect above its siblings, which is how the old bar
/// ended up on top of the recording controls on Enrique's phone (build 83).
/// - Holding (unlocked): red dot, timer, live waveform, "Slide to cancel", and the lock above the
///   mic the finger is still on (drawn here; the touch is `VoiceMicTouchHost`'s).
/// - Locked: Delete, timer, lock, waveform, Pause, Send.
/// - Paused: Delete, timer, "Paused", waveform, Resume, Send.
/// Every control is a plain Button, at least 44 pt, with a rectangular hit shape.
/// Nothing is sent or transcribed until Send, or the release of an unlocked hold.
struct VoiceNoteRecordingSurface: View {
    let elapsed: TimeInterval
    let levels: [CGFloat]
    let isLocked: Bool
    let isPaused: Bool
    /// The microphone prompt is up; the note starts once it is answered.
    var isRequestingPermission = false
    /// How far the held finger has slid toward cancel, 0...1.
    var cancelProgress: CGFloat = 0
    /// How far it has swiped up toward the lock, 0...1.
    var lockProgress: CGFloat = 0
    let onSend: () -> Void
    let onDelete: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    #if DEBUG
    @State private var probe = VoiceNoteHitTestProbe()
    #endif

    static let minimumTarget: CGFloat = 44
    static let barHeight: CGFloat = 64
    static let cornerRadius: CGFloat = 32

    var body: some View {
        Group {
            if isLocked || isPaused {
                lockedBar
            } else {
                holdingBar
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Self.barHeight)
        // Opaque, no glass, over the whole bar: nothing behind it can be seen or pressed.
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 14, y: 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceNote.surface")
    }

    private var timer: some View {
        Text(AudioDurationFormatter.string(from: elapsed))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.primary)
            .accessibilityIdentifier("voiceNote.timer")
    }

    private var holdingBar: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .opacity(isRequestingPermission ? 0.3 : 1)
            timer
            VoiceNoteWaveformView(levels: levels, barCount: 14)
            Spacer(minLength: 4)
            Label("Slide to cancel", systemImage: "chevron.left")
                .font(.caption)
                .foregroundStyle(cancelProgress > 0.6 ? Color.red : Color.secondary)
                .opacity(1 - Double(cancelProgress) * 0.5)
                .offset(x: -cancelProgress * 24)
            heldMic
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceNote.holdBar")
    }

    /// The mic under the finger, grown, with the lock it swipes toward. Drawn only: the touch is
    /// `VoiceMicTouchHost`'s, so this takes none.
    private var heldMic: some View {
        VStack(spacing: 2) {
            Image(systemName: lockProgress >= 1 ? "lock.fill" : "lock.open")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(0.5 + Double(lockProgress) * 0.5)
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .opacity(1 - Double(lockProgress))
            ZStack {
                Circle().fill(Color.red)
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .scaleEffect(reduceMotion ? 1 : 1 + lockProgress * 0.1)
        }
        .frame(width: 52)
        .accessibilityLabel(Text("Swipe up to lock"))
        .allowsHitTesting(false)
    }

    private var lockedBar: some View {
        HStack(spacing: 8) {
            control(id: "voiceNote.delete", label: "Delete voice note", action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: Self.minimumTarget, height: Self.minimumTarget)
            }

            Circle()
                .fill(isPaused ? Color.secondary : Color.red)
                .frame(width: 10, height: 10)
            timer
            if isPaused {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Locked"))
            }
            VoiceNoteWaveformView(levels: levels, color: isPaused ? .secondary : .red, barCount: isPaused ? 8 : 12)
                .layoutPriority(-1)

            Spacer(minLength: 4)

            if isPaused {
                control(id: "voiceNote.resume", label: "Resume", action: onResume) {
                    Label("Resume", systemImage: "mic.fill").font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .frame(minHeight: Self.minimumTarget)
                }
            } else {
                control(id: "voiceNote.pause", label: "Pause", action: onPause) {
                    Image(systemName: "pause.fill")
                        .frame(width: Self.minimumTarget, height: Self.minimumTarget)
                }
            }

            control(id: "voiceNote.send", label: "Send voice note", action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .frame(width: Self.minimumTarget, height: Self.minimumTarget)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceNote.bar")
    }

    /// One plain Button: its label at least 44 pt each way, a rectangular hit shape, no gesture
    /// beside it.
    private func control<Content: View>(id: String, label: LocalizedStringKey, action: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.record(id, frame: $0) }
        .task(id: id) { await probe.run() }
        #endif
    }
}

#if DEBUG
/// Debug-only hit-test probe: a moment after a control appears, asks UIKit what is under the
/// center of each recording control (`window.hitTest`) and logs it, so CI can fail if the old
/// text bar, the touch host or anything else sits on top of a control.
@MainActor
final class VoiceNoteHitTestProbe {
    private var frames: [String: CGRect] = [:]
    private var scheduled = false

    func record(_ id: String, frame: CGRect) {
        frames[id] = frame
    }

    func run() async {
        guard !scheduled else { return }
        scheduled = true
        try? await Task.sleep(nanoseconds: 900_000_000)
        scheduled = false
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        for (id, frame) in frames.sorted(by: { $0.key < $1.key }) where frame.width >= 1 {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let hit = window.hitTest(center, with: nil)
            var chain: [String] = []
            var view: UIView? = hit
            while let current = view, chain.count < 10 {
                chain.append(String(describing: type(of: current)))
                view = current.superview
            }
            let blocked = chain.contains { $0.contains("TextView") || $0.contains("HostView") || $0.contains("TouchHost") }
            JarvisClientLog.trace(String(format: "probe: %@ center=(%.0f,%.0f) size=%.0fx%.0f hit=%@ blocked=%@ chain=%@",
                                         id, center.x, center.y, frame.width, frame.height,
                                         hit.map { String(describing: type(of: $0)) } ?? "nil",
                                         blocked ? "true" : "false", chain.joined(separator: " < ")))
        }
    }
}
#endif

/// The voice note's haptics: start, lock, send, cancel, and a refused start.
@MainActor
enum VoiceNoteHaptics {
    static func started() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func locked() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func sent() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func cancelled() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func refused() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
