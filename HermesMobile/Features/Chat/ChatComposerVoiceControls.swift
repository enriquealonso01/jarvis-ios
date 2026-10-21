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

/// The composer mic, WhatsApp-style (JARVIS requirement 12):
/// - press and hold: a voice note records at once;
/// - while holding, swipe up to lock it (hands-free; releasing no longer sends), or slide left
///   to cancel it;
/// - release without locking: send;
/// - a quick tap leaves the note recording, locked, with Pause, Delete and Send in the bar.
/// With "Tap Mic for Voice Note" off, a quick tap toggles dictation as in Hermex and a hold
/// past `holdActivationDelay` records. One `DragGesture(minimumDistance: 0)` handles all of it.
struct ComposerVoiceControlButton: View {
    let isListening: Bool
    let isDisabled: Bool
    let color: Color
    let isRecordingVoiceNote: Bool
    var supportsVoiceNotes = true
    /// A tap records a locked note (true) or toggles dictation (false).
    var tapRecords = true
    /// The note in progress is locked: a release does nothing.
    var isLocked = false
    /// Dictation (tap with `tapRecords` off) and VoiceOver's default action.
    let onTap: () -> Void
    /// Touch-down (or the hold delay): start an unlocked note.
    let onPressBegan: () -> Void
    /// The finger's offset while holding a note, `.zero` when it lifts.
    var onDrag: (CGSize) -> Void = { _ in }
    let onLock: () -> Void
    let onCancel: () -> Void
    /// An unlocked hold was released: send.
    let onRelease: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressing = false
    @State private var didStart = false
    @State private var isHandled = false
    @State private var ignoresPress = false
    @State private var pressBegan = Date()
    @State private var holdWorkItem: DispatchWorkItem?

    @ViewBuilder var body: some View {
        if supportsVoiceNotes {
            label
                .gesture(pressGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    // VoiceOver synthesizes an activation rather than a real touch, so the
                    // gesture never fires: start a locked note (or dictate).
                    guard !isDisabled, !isRecordingVoiceNote else { return }
                    if tapRecords { onPressBegan(); onLock() } else { onTap() }
                }
                .accessibilityAction(named: Text("Record voice note")) {
                    onPressBegan()
                    onLock()
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
            .scaleEffect(reduceMotion ? 1 : (isPressing && didStart ? 1.5 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isPressing && didStart)
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

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    pressBegan = Date()
                    didStart = false
                    isHandled = false
                    // A note already in progress is driven from its bar; this press does nothing.
                    ignoresPress = isRecordingVoiceNote || isDisabled
                    guard !ignoresPress else { return }
                    if tapRecords {
                        didStart = true
                        onPressBegan()
                    } else {
                        scheduleHold()
                    }
                    return
                }
                guard didStart, !isHandled, !ignoresPress else { return }
                onDrag(value.translation)
                switch ComposerVoiceNoteGesture.dragAction(translation: value.translation) {
                case .lock:
                    isHandled = true
                    onDrag(.zero)
                    onLock()
                case .cancel:
                    isHandled = true
                    onDrag(.zero)
                    onCancel()
                case .none:
                    break
                }
            }
            .onEnded { _ in
                cancelHold()
                let sawTouchDown = isPressing
                defer {
                    isPressing = false
                    didStart = false
                    isHandled = false
                    ignoresPress = false
                }
                // A very quick tap can arrive as an end with no touch-down update (Maestro's taps
                // do, run 39652026792): treat it as the tap it is.
                guard sawTouchDown else {
                    guard !isRecordingVoiceNote, !isDisabled else { return }
                    if tapRecords { onPressBegan(); onLock() } else { onTap() }
                    return
                }
                guard !ignoresPress else { return }
                guard didStart else {
                    // Released before the hold delay with taps set to dictate.
                    if !isDisabled { onTap() }
                    return
                }
                onDrag(.zero)
                switch ComposerVoiceNoteGesture.releaseAction(
                    isLocked: isLocked, wasCancelled: isHandled, heldFor: Date().timeIntervalSince(pressBegan)
                ) {
                case .send: onRelease()
                case .lock: onLock()
                case .none: break
                }
            }
    }

    private func scheduleHold() {
        let item = DispatchWorkItem {
            didStart = true
            onPressBegan()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ComposerVoiceNoteGesture.holdActivationDelay, execute: item)
    }

    private func cancelHold() {
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

/// The bar above the composer while a voice note is in progress.
/// - Holding (not locked): timer, live waveform, "< Slide to cancel" and the lock hint.
/// - Locked: Delete, timer, waveform, Pause, Send.
/// - Paused: Delete, timer, "Paused", Resume (records into the same note), Send.
/// Nothing is sent or transcribed until Send.
struct ComposerVoiceRecordingBar: View {
    let elapsed: TimeInterval
    let levels: [CGFloat]
    let isLocked: Bool
    let isPaused: Bool
    /// How far the held finger has slid toward cancel, 0...1.
    var cancelProgress: CGFloat = 0
    let onSend: () -> Void
    let onDelete: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        Group {
            if isLocked || isPaused {
                lockedBar
            } else {
                holdingBar
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
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
            timer
            VoiceNoteWaveformView(levels: levels, barCount: 16)
            Spacer(minLength: 4)
            Label("Slide to cancel", systemImage: "chevron.left")
                .font(.caption)
                .foregroundStyle(cancelProgress > 0.6 ? Color.red : Color.secondary)
                .opacity(1 - Double(cancelProgress) * 0.5)
            VStack(spacing: 0) {
                Image(systemName: "lock")
                Image(systemName: "chevron.up").font(.caption2)
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Swipe up to lock"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceNote.holdBar")
    }

    private var lockedBar: some View {
        HStack(spacing: 10) {
            Button(action: onDelete) {
                Image(systemName: "trash").frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Delete voice note"))
            .accessibilityIdentifier("voiceNote.delete")

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
            VoiceNoteWaveformView(levels: levels, color: isPaused ? .secondary : .red, barCount: 12)

            Spacer(minLength: 4)

            if isPaused {
                Button(action: onResume) {
                    Label("Resume", systemImage: "mic.fill").font(.callout.weight(.semibold))
                }
                .accessibilityIdentifier("voiceNote.resume")
            } else {
                Button(action: onPause) {
                    Image(systemName: "pause.fill").frame(width: 36, height: 36)
                }
                .accessibilityLabel(Text("Pause"))
                .accessibilityIdentifier("voiceNote.pause")
            }

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(Text("Send voice note"))
            .accessibilityIdentifier("voiceNote.send")
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceNote.bar")
    }
}

/// The voice note's haptics: start, lock, send, cancel, and a refused start.
@MainActor
enum VoiceNoteHaptics {
    static func started() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func locked() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func sent() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func cancelled() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func refused() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
