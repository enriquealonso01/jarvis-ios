import Foundation
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

/// The composer mic. A quick **tap** toggles on-device dictation (unchanged); a
/// **press-and-hold** records a server-transcribed voice note, releasing to send
/// and sliding up to cancel. Both paths run through a single
/// `DragGesture(minimumDistance: 0)`: touch-down schedules a `DispatchWorkItem`
/// after the hold threshold, and a release before it fires cancels the item and
/// counts as a tap → dictation. See `pressGesture` for why timing beats composing
/// `LongPressGesture`/`TapGesture`.
struct ComposerVoiceControlButton: View {
    let isListening: Bool
    let isDisabled: Bool
    let color: Color
    let isRecordingVoiceNote: Bool
    var supportsVoiceNotes = true
    let onTap: () -> Void
    let onRecordingStart: () -> Void
    let onRecordingDragChanged: (CGFloat) -> Void
    let onRecordingEnd: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressing = false
    @State private var didTriggerRecording = false
    @State private var holdWorkItem: DispatchWorkItem?

    @ViewBuilder var body: some View {
        if supportsVoiceNotes {
            label
                .gesture(pressGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    // VoiceOver synthesizes an activation rather than a real touch,
                    // so the gesture's tap path never fires for it.
                    if !isDisabled { onTap() }
                }
                .accessibilityAction(named: Text("Record voice note")) {
                    // VoiceOver can't hold-to-talk, so this starts recording; the
                    // recording bar then exposes "Stop and send" / "Cancel" actions.
                    onRecordingStart()
                }
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
            .scaleEffect(reduceMotion ? 1 : (isRecordingVoiceNote ? 1.3 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isRecordingVoiceNote)
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

    /// One `DragGesture(minimumDistance: 0)` distinguishes tap from hold by timing,
    /// which is far more reliable than composing `LongPressGesture`/`TapGesture`/
    /// `highPriorityGesture` (those let the press keep claiming the touch so the tap
    /// never wins). Touch-down schedules a delayed "start recording"; a release
    /// before the delay cancels it and counts as a tap → dictation. A perfectly
    /// still hold still records because the delay is timer-driven, not movement-driven.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    scheduleRecordingStart()
                }
                if isRecordingVoiceNote {
                    onRecordingDragChanged(value.translation.height)
                }
            }
            .onEnded { value in
                cancelScheduledRecordingStart()
                let triggered = didTriggerRecording
                isPressing = false
                didTriggerRecording = false

                if triggered {
                    onRecordingEnd(value.translation.height)
                } else if !isDisabled {
                    onTap()
                }
            }
    }

    private func scheduleRecordingStart() {
        didTriggerRecording = false
        let item = DispatchWorkItem {
            didTriggerRecording = true
            onRecordingStart()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ComposerVoiceNoteGesture.holdActivationDelay,
            execute: item
        )
    }

    private func cancelScheduledRecordingStart() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }
}

enum ComposerVoiceControlAccessibility {
    static func label(isListening: Bool, isRecordingVoiceNote: Bool) -> String {
        if isRecordingVoiceNote { return String(localized: "Recording voice note") }
        return isListening ? String(localized: "Stop voice input") : String(localized: "Voice input")
    }
}

/// Telegram-style indicator shown above the composer while a voice note records:
/// a pulsing red dot, an `m:ss` timer, and a slide-to-cancel hint that turns red
/// once the cancel threshold is armed. Exposes explicit VoiceOver actions because
/// the hold-to-talk gesture isn't reachable with VoiceOver on.
struct ComposerVoiceRecordingBar: View {
    let elapsed: TimeInterval
    let isCancelArmed: Bool
    let onStop: () -> Void
    let onCancel: () -> Void
    /// JARVIS: a paused note (interrupted, or paused by the user) offers Continue, Send, Delete.
    var isPaused = false
    /// JARVIS: a note started with a tap records hands-free, with Delete, Pause and Send.
    var isHandsFree = false
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}

    var body: some View {
        if isPaused || isHandsFree {
            jarvisControls
        } else {
            holdToTalkBar
        }
    }

    /// The paused and hands-free bar: never finishes a note by itself.
    private var jarvisControls: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "trash").frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Delete voice note"))
            .accessibilityIdentifier("voiceNote.delete")

            Circle()
                .fill(isPaused ? Color.secondary : Color.red)
                .frame(width: 10, height: 10)
            Text(AudioDurationFormatter.string(from: elapsed))
                .font(.callout.monospacedDigit())
            if isPaused {
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: isPaused ? onResume : onPause) {
                Label(isPaused ? "Continue" : "Pause", systemImage: isPaused ? "mic.fill" : "pause.fill")
                    .font(.callout.weight(.semibold))
            }
            .accessibilityIdentifier(isPaused ? "voiceNote.continue" : "voiceNote.pause")

            Button(action: onStop) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Send voice note"))
            .accessibilityIdentifier("voiceNote.send")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceNote.bar")
    }

    private var holdToTalkBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(isCancelArmed ? 0.4 : 1)

            Text(AudioDurationFormatter.string(from: elapsed))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Label(
                isCancelArmed
                    ? String(localized: "Release to cancel")
                    : String(localized: "Slide up to cancel"),
                systemImage: isCancelArmed ? "xmark.circle.fill" : "chevron.up"
            )
            .font(.caption)
            .foregroundStyle(isCancelArmed ? Color.red : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Recording voice note, \(AudioDurationFormatter.string(from: elapsed))"))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(named: Text("Stop and send"), onStop)
        .accessibilityAction(named: Text("Cancel recording"), onCancel)
    }
}
