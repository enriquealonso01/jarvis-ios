import ActivityKit
import Foundation
import UIKit

/// The Action button's toggle: one shared controller, so a second press stops the
/// recording the first started, from any entry point, foreground or locked. The pill
/// (`QuickVoiceActivityAttributes`) is its only UI: red dot, a system timer and one
/// message line while recording; the send's progress once the clip exists; a tap target
/// once the new chat exists.
///
/// The pill goes up BEFORE the recorder starts: a recording `QuickVoiceIntent` starts in
/// the background lasts only while a Live Activity is up (`AudioRecordingIntent`), so a
/// press that cannot show the pill records nothing and says why. The second press returns
/// as soon as the clip is stopped; the send runs on in background time with the pill
/// showing its progress, so the Action button never spins through a transcription.
@MainActor
final class QuickVoiceController {
    static let shared = QuickVoiceController()

    enum Phase: Equatable {
        case idle
        case recording
        case sending
    }

    enum Outcome {
        /// The chat the note opened, for the pill's tap target.
        case sent(URL)
        case failed(String)
    }

    /// What one press did. Only `.refused` has nothing on screen: the intent hands its
    /// reason to the system to show.
    enum Press: Equatable {
        /// Recording; the pill counts up.
        case recording
        /// Stopped; the pill shows the send.
        case sending
        /// The last note is still sending; the pill shows it.
        case busy
        /// Nothing was sent (the mic refused, an empty or too short clip); the pill says why.
        case notSent
        /// No pill could be shown, so nothing was recorded.
        case refused(String)
        /// A second run of the same press (within `repeatWindow` of the last one): nothing done.
        case repeated
    }

    /// A clip shorter than this is a double press, not a note: it is dropped, not sent.
    static let minimumDuration: TimeInterval = 1
    /// The system can run the Action button's intent twice for one press; a run this soon
    /// after the last is that press again, and must not stop the clip it just started.
    static let repeatWindow: TimeInterval = 1

    private(set) var phase: Phase = .idle
    /// The running or last send, so tests can wait for it.
    private(set) var sendTask: Task<Void, Never>?
    private var recorder: (any QuickVoiceRecording)?
    private var lastPress: Date?

    private let makeRecorder: () -> any QuickVoiceRecording
    private let deliver: @MainActor (Data) async -> Outcome
    private let pill: any QuickVoicePill
    private let isInFront: @MainActor () -> Bool
    private let now: () -> Date

    /// The live path: records for real, shows the Live Activity, sends over the shared connection.
    convenience init() {
        self.init(makeRecorder: { QuickVoiceRecorder() },
                  deliver: { await QuickVoiceSender.deliver($0) },
                  pill: QuickVoiceLiveActivityPill(),
                  isInFront: { UIApplication.shared.applicationState == .active },
                  now: { Date() })
    }

    init(makeRecorder: @escaping () -> any QuickVoiceRecording,
         deliver: @escaping @MainActor (Data) async -> Outcome,
         pill: any QuickVoicePill,
         isInFront: @escaping @MainActor () -> Bool = { false },
         now: @escaping () -> Date = { Date() }) {
        self.makeRecorder = makeRecorder
        self.deliver = deliver
        self.pill = pill
        self.isInFront = isInFront
        self.now = now
    }

    /// The Action button's single entry: starts a recording, or stops the one running and
    /// sends it.
    @discardableResult
    func toggle() async -> Press {
        let pressedAt = now()
        if let lastPress, pressedAt.timeIntervalSince(lastPress) < Self.repeatWindow {
            return .repeated
        }
        lastPress = pressedAt
        switch phase {
        case .recording: return await stop()
        case .sending: return .busy
        case .idle: return await start()
        }
    }

    private func start() async -> Press {
        // A pill an earlier press left up (its last line, or a recording a process that
        // died never ended) goes first, so a press never shows two.
        await pill.clearLeftovers()
        guard pill.show(.recording, message: String(localized: "JARVIS listening…")) else {
            return .refused(String(localized: "Turn on Live Activities for JARVIS in Settings to record with Quick Voice."))
        }
        let recorder = makeRecorder()
        let exclusive = isInFront()
        do {
            try recorder.start(exclusive: exclusive)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Recording could not start.") + " (\(HermesConnectionLog.reason(error)))"
            JarvisClientLog.record("quickVoice", "recording refused (exclusive=\(exclusive)): \(message)")
            await end(saying: message)
            return .notSent
        }
        if recorder.usesEngine {
            JarvisClientLog.record("quickVoice", "recorder said no; recording through the engine (exclusive=\(exclusive))")
        }
        self.recorder = recorder
        phase = .recording
        return .recording
    }

    /// Stops the clip and hands it to the send, which runs on after this returns.
    private func stop() async -> Press {
        guard let recorder else {
            phase = .idle
            return .notSent
        }
        self.recorder = nil
        guard let clip = recorder.stop(), !clip.audio.isEmpty else {
            await end(saying: String(localized: "Nothing was recorded."))
            return .notSent
        }
        guard clip.duration >= Self.minimumDuration else {
            await end(saying: String(localized: "Too short to send. Press once to start, and again when you're done."))
            return .notSent
        }
        phase = .sending
        await pill.update(.sending, message: String(localized: "Sending…"), destinationURL: nil)
        sendTask = Task { await self.send(clip.audio) }
        return .sending
    }

    private func send(_ audio: Data) async {
        // After the clip stops nothing keeps a background app running, so the send asks for
        // background time. If that runs out first, the send finishes when JARVIS next runs.
        var backgroundTask = UIBackgroundTaskIdentifier.invalid
        let endBackgroundTask = {
            guard backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "JARVIS Quick Voice send") { [weak self] in
            Task { @MainActor in
                await self?.pill.update(.sending, message: String(localized: "Open JARVIS to finish sending."),
                                        destinationURL: nil)
                endBackgroundTask()
            }
        }
        defer { endBackgroundTask() }

        switch await deliver(audio) {
        case .sent(let url):
            await pill.update(.done, message: String(localized: "Sent to a new chat."), destinationURL: url)
        case .failed(let reason):
            JarvisClientLog.record("quickVoice", "send failed: \(reason)")
            await pill.update(.failed, message: reason, destinationURL: nil)
        }
        await pill.finish()
        phase = .idle
    }

    /// Ends a press that sends nothing: the pill says why for a few seconds.
    private func end(saying message: String) async {
        phase = .idle
        await pill.update(.failed, message: message, destinationURL: nil)
        await pill.finish()
    }
}

/// Quick Voice's pill, behind a seam so the toggle runs in tests without ActivityKit.
@MainActor
protocol QuickVoicePill: AnyObject {
    /// Ends at once every Quick Voice pill still on screen.
    func clearLeftovers() async
    /// Puts up a new pill; false when the system refused it.
    func show(_ phase: QuickVoiceActivityAttributes.Phase, message: String) -> Bool
    func update(_ phase: QuickVoiceActivityAttributes.Phase, message: String, destinationURL: URL?) async
    /// Ends the pill with its last line kept on screen for a few seconds.
    func finish() async
}

/// The live pill: the Quick Voice Live Activity on the Lock Screen and in the Dynamic Island.
@MainActor
final class QuickVoiceLiveActivityPill: QuickVoicePill {
    private var activity: Activity<QuickVoiceActivityAttributes>?

    func clearLeftovers() async {
        activity = nil
        for leftover in Activity<QuickVoiceActivityAttributes>.activities {
            await leftover.end(nil, dismissalPolicy: .immediate)
        }
    }

    func show(_ phase: QuickVoiceActivityAttributes.Phase, message: String) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            JarvisClientLog.record("quickVoice", "Live Activities are off for JARVIS")
            return false
        }
        let state = QuickVoiceActivityAttributes.ContentState(
            phase: phase, startedAt: Date(), message: message, destinationURL: nil)
        do {
            activity = try Activity.request(attributes: QuickVoiceActivityAttributes(),
                                            content: ActivityContent(state: state, staleDate: nil))
            return true
        } catch {
            JarvisClientLog.record("quickVoice", "Live Activity refused: \(error.localizedDescription)")
            return false
        }
    }

    func update(_ phase: QuickVoiceActivityAttributes.Phase, message: String, destinationURL: URL?) async {
        guard let activity else { return }
        var state = activity.content.state
        state.phase = phase
        state.message = message
        state.destinationURL = destinationURL
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func finish() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(activity.content, dismissalPolicy: .after(Date().addingTimeInterval(5)))
    }
}
