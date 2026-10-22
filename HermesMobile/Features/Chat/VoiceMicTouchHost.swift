import SwiftUI
import UIKit

/// What the mic's press needs to know at the moment of each touch event.
struct VoiceMicPressContext: Equatable {
    /// A tap records a locked note (true) or toggles dictation (false).
    var tapRecords: Bool
    /// The note in progress is locked: a release does nothing.
    var isLocked: Bool
    var noteInProgress: Bool
    var isDisabled: Bool
}

/// What a press does to the composer, fed by `ComposerVoiceNoteGesture.Tracker`.
struct VoiceMicPressHandlers {
    var onPressBegan: () -> Void = {}
    var onDrag: (CGSize) -> Void = { _ in }
    var onLock: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRelease: () -> Void = {}
    var onTap: () -> Void = {}
}

/// The mic's touch, in UIKit, on a view that outlives the composer's swap.
///
/// While a voice note is recorded the composer shows ONLY the recording bar: the text bar, its
/// field, the camera and the mic are not in the view tree (Enrique, build 83: the old bar sat on
/// top of the recording bar and its buttons couldn't be pressed). The finger that started the
/// note is still down on the mic that was just removed, and a SwiftUI gesture dies with its view.
/// This transparent host sits over the composer, takes touches only inside `micRect` (the mic's
/// last frame), and keeps tracking that finger through the swap, so swipe up to lock and slide
/// left to cancel keep working.
///
/// It is torn down the moment the note locks or the finger lifts: `micRect` goes to zero, the
/// recognizer is disabled, and `point(inside:)` refuses every touch, so the recording bar's
/// plain buttons (Delete, Pause, Resume, Send) are never shadowed by it.
struct VoiceMicTouchHost: UIViewRepresentable {
    /// The mic's frame in this view's coordinate space; `.zero` when there is nothing to press.
    var micRect: CGRect
    var isEnabled: Bool
    var context: () -> VoiceMicPressContext
    var handlers: VoiceMicPressHandlers

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.cancelsTouchesInView = true
        view.addGestureRecognizer(recognizer)
        view.recognizer = recognizer
        return view
    }

    func updateUIView(_ view: HostView, context coordinatorContext: Context) {
        let coordinator = coordinatorContext.coordinator
        coordinator.contextProvider = context
        coordinator.handlers = handlers
        let live = isEnabled && !micRect.isEmpty
        view.micRect = live ? micRect : .zero
        if let recognizer = view.recognizer, recognizer.isEnabled != live { recognizer.isEnabled = live }
    }

    final class HostView: UIView {
        var micRect: CGRect = .zero
        weak var recognizer: UILongPressGestureRecognizer?

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard recognizer?.isEnabled == true, !micRect.isEmpty else { return false }
            return micRect.contains(point)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var contextProvider: () -> VoiceMicPressContext = {
            VoiceMicPressContext(tapRecords: true, isLocked: false, noteInProgress: false, isDisabled: true)
        }
        var handlers = VoiceMicPressHandlers()
        private var tracker = ComposerVoiceNoteGesture.Tracker()
        private var startLocation: CGPoint = .zero
        private var holdWorkItem: DispatchWorkItem?

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                startLocation = recognizer.location(in: nil)
                deliver(.touchDown(Date()))
            case .changed:
                let location = recognizer.location(in: nil)
                deliver(.moved(CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y)))
            case .ended:
                deliver(.released(Date()))
            case .cancelled, .failed:
                // The system took the touch (a call, the app switcher, the lock screen), or the
                // note locked and the host was disabled under the finger.
                if tracker.isPressing { deliver(.cancelled) }
            default:
                break
            }
        }

        /// One touch event, run through the press state machine. Also the entry point for tests.
        func deliver(_ event: ComposerVoiceNoteGesture.Event) {
            switch event {
            case .released, .cancelled: cancelHold()
            default: break
            }
            run(apply(event))
            if case .touchDown = event, tracker.awaitsHoldDelay { scheduleHold() }
        }

        private func apply(_ event: ComposerVoiceNoteGesture.Event) -> [ComposerVoiceNoteGesture.Effect] {
            let press = contextProvider()
            return tracker.apply(event, tapRecords: press.tapRecords, isLocked: press.isLocked,
                                 noteInProgress: press.noteInProgress, isDisabled: press.isDisabled)
        }

        private func run(_ effects: [ComposerVoiceNoteGesture.Effect]) {
            for effect in effects {
                switch effect {
                case .begin: handlers.onPressBegan()
                case .drag(let translation): handlers.onDrag(translation)
                case .lock: handlers.onLock()
                case .cancel: handlers.onCancel()
                case .send: handlers.onRelease()
                case .tap: handlers.onTap()
                }
            }
        }

        private func scheduleHold() {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.run(self.apply(.holdDelayElapsed))
            }
            holdWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + ComposerVoiceNoteGesture.holdActivationDelay, execute: item)
        }

        private func cancelHold() {
            holdWorkItem?.cancel()
            holdWorkItem = nil
        }
    }
}
