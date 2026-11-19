import ActivityKit
import Foundation

/// The Action button's toggle: one shared controller, so a second press stops the
/// recording the first started, from any entry point, foreground or locked. The pill
/// (`QuickVoiceActivityAttributes`) is its only UI: red dot, a system timer and one
/// message line while recording; the send's progress once the clip exists; a tap target
/// once the new chat exists. Recording runs over the app's `audio` background mode.
@MainActor
final class QuickVoiceController {
    static let shared = QuickVoiceController()

    enum Phase: Equatable {
        case idle
        case recording
        case sending
        case done
        case failed
    }

    enum Outcome {
        /// The chat the note opened, for the pill's tap target.
        case sent(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var recorder: (any QuickVoiceRecording)?
    private var activity: Activity<QuickVoiceActivityAttributes>?
    private var sendTask: Task<Void, Never>?

    /// Injectable for tests; the live path records for real and sends over the shared
    /// connection.
    private var makeRecorder: () -> any QuickVoiceRecording
    private var deliver: (Data) async -> Outcome

    init(makeRecorder: @escaping () -> any QuickVoiceRecording = { QuickVoiceRecorder() },
         deliver: @escaping (Data) async -> Outcome = { await QuickVoiceSender.deliver($0) }) {
        self.makeRecorder = makeRecorder
        self.deliver = deliver
    }

    /// The Action button's single entry: starts a recording, or concludes the one
    /// running. Returns false only when a start was refused outright (mic off).
    @discardableResult
    func toggle() async -> Bool {
        switch phase {
        case .recording:
            await stopAndSend()
            return true
        case .idle, .done, .failed:
            return await start()
        case .sending:
            return true
        }
    }

    /// Starts recording and shows the pill. A recorder that cannot start fails the pill
    /// with its reason; a pill that cannot be requested records on without it.
    private func start() async -> Bool {
        let recorder = makeRecorder()
        do {
            try recorder.start()
        } catch {
            phase = .failed
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "Recording could not start.")
            await requestActivity(phase: .failed, message: message)
            await endActivityAfterDismissal()
            phase = .idle
            return false
        }
        self.recorder = recorder
        phase = .recording
        await requestActivity(phase: .recording, message: String(localized: "JARVIS listening…"))
        return true
    }

    /// Stops the clip, ends the timer state and sends the clip through the voice-note
    /// path. The send runs while the pill shows its progress.
    func stopAndSend() async {
        guard phase == .recording, let recorder else { return }
        self.recorder = nil
        let audio = recorder.stop()
        guard let audio, !audio.isEmpty else {
            phase = .failed
            await updateActivity(phase: .failed, message: String(localized: "Nothing was recorded."))
            await endActivityAfterDismissal()
            phase = .idle
            return
        }
        phase = .sending
        await updateActivity(phase: .sending, message: String(localized: "Sending…"))
        let outcome = await deliver(audio)
        switch outcome {
        case .sent(let url):
            phase = .done
            await updateActivity(phase: .done,
                                 message: String(localized: "Sent to a new chat."),
                                 destinationURL: url)
        case .failed(let reason):
            phase = .failed
            await updateActivity(phase: .failed, message: reason)
        }
        await endActivityAfterDismissal()
        phase = .idle
    }

    // MARK: - Live Activity

    private func requestActivity(phase: QuickVoiceActivityAttributes.Phase, message: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = QuickVoiceActivityAttributes.ContentState(
            phase: phase, startedAt: Date(), message: message, destinationURL: nil, schemaVersion: 1)
        activity = try? Activity.request(attributes: QuickVoiceActivityAttributes(),
                                         content: ActivityContent(state: state, staleDate: nil))
    }

    private func updateActivity(phase: QuickVoiceActivityAttributes.Phase, message: String,
                                destinationURL: URL? = nil) async {
        guard let activity else { return }
        var state = activity.content.state
        state.phase = phase
        state.message = message
        state.destinationURL = destinationURL
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// Ends the activity with its final state kept on screen, as Voice Memos' pill
    /// keeps its result, then forgets it so the next recording requests a fresh one.
    private func endActivityAfterDismissal() async {
        guard let activity else { return }
        self.activity = nil
        await activity.end(activity.content, dismissalPolicy: .after(Date().addingTimeInterval(5)))
    }
}
