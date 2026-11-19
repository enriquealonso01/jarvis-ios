import AVFoundation
import Foundation

/// What Quick Voice records with, so the controller's state machine runs in tests
/// without a microphone.
protocol QuickVoiceRecording {
    func start() throws
    /// Stops and returns the recorded clip; nil when nothing usable was captured.
    func stop() -> Data?
}

/// Quick Voice's own recorder, separate from the composer's
/// (`ComposerVoiceNoteRecorder` is untouched): one clip per press, to a temporary
/// `.m4a` with the composer's AAC settings, over the app's one audio session.
/// Permission must already be granted — the Action button runs while the phone is
/// locked, where the system prompt cannot appear.
final class QuickVoiceRecorder: QuickVoiceRecording {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func start() throws {
        guard VoiceNoteMicrophonePermission.current == .granted else {
            throw QuickVoiceError.microphoneOff
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-voice-\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: ComposerVoiceNoteRecorder.recordingSettings)
        guard recorder.record() else { throw QuickVoiceError.startFailed }
        self.recorder = recorder
        fileURL = url
    }

    func stop() -> Data? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let fileURL, let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: fileURL)
        self.fileURL = nil
        return data
    }
}

enum QuickVoiceError: LocalizedError {
    case microphoneOff
    case startFailed
    case transcriptionRefused

    var errorDescription: String? {
        switch self {
        case .microphoneOff:
            return String(localized: "Microphone access is off. Turn it on in Settings > JARVIS to record voice notes.")
        case .startFailed:
            return String(localized: "Recording could not start.")
        case .transcriptionRefused:
            return String(localized: "The recording could not be transcribed.")
        }
    }
}
