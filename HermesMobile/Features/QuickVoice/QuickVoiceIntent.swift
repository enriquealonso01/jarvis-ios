import AppIntents
import Foundation

/// "Quick Voice" — the Action button's toggle (JARVIS Quick Voice). One press starts
/// recording from the shared `QuickVoiceController` without opening the app
/// (`openAppWhenRun = false`), so it works while the phone is locked; the next press
/// stops the clip and sends it through the voice-note path as a new chat's first
/// message, with the recording pill as the only UI. Mic permission is asked by the
/// composer's path beforehand — the Action button cannot show the system prompt while
/// locked, so a press without it fails the pill with the reason instead.
struct QuickVoiceIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Voice"
    static var description = IntentDescription(
        "Record a voice note for JARVIS without opening the app. Press once to record, again to send it to a new chat.")

    /// Never foregrounds the app: the whole point is recording while locked.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await QuickVoiceController.shared.toggle()
        return .result()
    }
}
