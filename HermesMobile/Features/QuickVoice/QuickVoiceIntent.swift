import AppIntents
import Foundation

/// "Quick Voice" — the Action button's toggle (JARVIS Quick Voice). One press starts
/// recording from the shared `QuickVoiceController` without opening the app
/// (`openAppWhenRun = false`), so it works while the phone is locked; the next press
/// stops the clip and sends it through the voice-note path as a new chat's first
/// message, with the recording pill as the only UI. Mic permission is asked by the
/// composer's path beforehand — the Action button cannot show the system prompt while
/// locked, so a press without it fails the pill with the reason instead.
///
/// It is an `AudioRecordingIntent` because iOS lets an app start recording from the
/// background only through one, and only while a Live Activity is up for the whole
/// recording (Apple: without it "the audio recording stops"). It is also a
/// `LiveActivityIntent`, which is what lets that Live Activity start while the app is not
/// in front. Build 100 shipped it as a plain `AppIntent`: from the Lock Screen or another
/// app both the recorder and the pill were refused, so most presses showed only the
/// system's check mark and recorded nothing.
struct QuickVoiceIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Quick Voice"
    static var description = IntentDescription(
        "Record a voice note for JARVIS without opening the app. Press once to record, again to send it to a new chat.")

    /// Never foregrounds the app: the whole point is recording while locked.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        // Only a press that could show nothing reports here; every other outcome is on the pill.
        if case .refused(let reason) = await QuickVoiceController.shared.toggle() {
            throw QuickVoiceRefusal(reason: reason)
        }
        return .result()
    }
}

/// A press with no pill to say why it did nothing: the system shows this reason in place of
/// its check mark.
struct QuickVoiceRefusal: Error, CustomLocalizedStringResourceConvertible, LocalizedError {
    let reason: String

    /// Already localized by the controller.
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: reason) }
    var errorDescription: String? { reason }
}
