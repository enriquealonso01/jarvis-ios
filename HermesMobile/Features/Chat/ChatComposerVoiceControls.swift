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
/// past `holdActivationDelay` records. One `DragGesture(minimumDistance: 0)` feeds
/// `ComposerVoiceNoteGesture.Tracker`, which decides; a touch the system takes away (a call,
/// the app switcher, the lock screen) ends as `.cancelled`, so no press is ever left armed.
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
    @State private var tracker = ComposerVoiceNoteGesture.Tracker()
    @GestureState private var isTouching = false
    @State private var holdWorkItem: DispatchWorkItem?

    @ViewBuilder var body: some View {
        if supportsVoiceNotes {
            label
                .gesture(pressGesture)
                .onChange(of: isTouching) { _, touching in
                    guard !touching else { return }
                    // The gesture ended without `onEnded`: the system took the touch. Checked a
                    // tick later, once a normal end has settled the tracker.
                    DispatchQueue.main.async {
                        guard tracker.isPressing else { return }
                        cancelHold()
                        run(apply(.cancelled))
                    }
                }
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
            .updating($isTouching) { _, state, _ in state = true }
            .onChanged { value in
                if !tracker.isPressing {
                    run(apply(.touchDown(Date())))
                    if tracker.awaitsHoldDelay { scheduleHold() }
                }
                run(apply(.moved(value.translation)))
            }
            .onEnded { _ in
                cancelHold()
                run(apply(.released(Date())))
            }
    }

    private func apply(_ event: ComposerVoiceNoteGesture.Event) -> [ComposerVoiceNoteGesture.Effect] {
        tracker.apply(event, tapRecords: tapRecords, isLocked: isLocked, noteInProgress: isRecordingVoiceNote,
                      isDisabled: isDisabled)
    }

    private func run(_ effects: [ComposerVoiceNoteGesture.Effect]) {
        for effect in effects {
            switch effect {
            case .begin: onPressBegan()
            case .drag(let translation): onDrag(translation)
            case .lock: onLock()
            case .cancel: onCancel()
            case .send: onRelease()
            case .tap: onTap()
            }
        }
    }

    private func scheduleHold() {
        let item = DispatchWorkItem { run(apply(.holdDelayElapsed)) }
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

/// The input bar while a voice note is in progress (Signal/WhatsApp): it takes the bar's whole
/// surface, text field included.
/// - Holding (unlocked): red dot, timer, live waveform, "Slide to cancel", and the lock hint
///   above the mic the finger holds (drawn here, large, in the mic's slot).
/// - Locked: Delete, timer, lock, waveform, Pause, Send.
/// - Paused: Delete, timer, "Paused", waveform, Resume, Send.
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

    var body: some View {
        Group {
            if isLocked || isPaused {
                lockedBar
            } else {
                holdingBar
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// The mic under the finger, grown, with the lock it swipes toward.
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
        HStack(spacing: 10) {
            Button(action: onDelete) {
                Image(systemName: "trash").frame(width: 40, height: 40)
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
                        .frame(minHeight: 40)
                }
                .accessibilityIdentifier("voiceNote.resume")
            } else {
                Button(action: onPause) {
                    Image(systemName: "pause.fill").frame(width: 40, height: 40)
                }
                .accessibilityLabel(Text("Pause"))
                .accessibilityIdentifier("voiceNote.pause")
            }

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .frame(width: 44, height: 44)
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
