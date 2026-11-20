import AVFoundation
import Foundation

/// One stopped recording: the file's bytes and how long it ran.
struct QuickVoiceClip: Equatable {
    let audio: Data
    let duration: TimeInterval
}

/// What Quick Voice records with, so the controller's state machine runs in tests
/// without a microphone.
protocol QuickVoiceRecording {
    /// `exclusive` when JARVIS is in front: other audio pauses for the note. From the
    /// background the session mixes with other audio and ducks it, the only first
    /// activation iOS lets a background start make.
    func start(exclusive: Bool) throws
    /// Stops and returns the recorded clip; nil when nothing usable was captured.
    func stop() -> QuickVoiceClip?
    /// True when the running clip records through the engine fallback, for the client log.
    var usesEngine: Bool { get }
}

/// Quick Voice's own recorder, separate from the composer's
/// (`ComposerVoiceNoteRecorder` is untouched): one clip per press, to a temporary
/// `.m4a`, over the app's one audio session. Permission must already be granted — the
/// Action button runs while the phone is locked, where the system prompt cannot appear.
///
/// Build 101 activated the composer's exclusive session (`.playAndRecord`, no mixing) from
/// the background, which iOS refuses (`cannotInterruptOthers`): every locked press said
/// "Recording could not start." A background press now makes a mixable, ducking session
/// its first activation, as other apps that record from the Action button do. When
/// `AVAudioRecorder.record()` still says no on that active session (it can while another
/// app speaks), an `AVAudioEngine` input records on the same session instead, with no
/// second activation. A start that fails names its step and the system's code.
final class QuickVoiceRecorder: QuickVoiceRecording {
    private var recorder: AVAudioRecorder?
    private var engine: AVAudioEngine?
    private var engineFile: QuickVoiceEngineFile?
    private var fileURL: URL?
    private var startedAt: Date?
    var usesEngine: Bool { engine != nil }

    func start(exclusive: Bool) throws {
        guard VoiceNoteMicrophonePermission.current == .granted else {
            throw QuickVoiceError.microphoneOff
        }
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = exclusive ? [.allowBluetoothHFP] : [.mixWithOthers, .duckOthers]
        try Self.step(.category) { try session.setCategory(.playAndRecord, mode: .default, options: options) }
        try Self.step(.activate) { try session.setActive(true) }
        do {
            let url = Self.newFileURL()
            if let recorder = try? AVAudioRecorder(url: url, settings: ComposerVoiceNoteRecorder.recordingSettings),
               recorder.record() {
                self.recorder = recorder
                fileURL = url
            } else {
                try? FileManager.default.removeItem(at: url)
                let engineURL = Self.newFileURL()
                try startEngine(writingTo: engineURL)
                fileURL = engineURL
            }
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        startedAt = Date()
    }

    func stop() -> QuickVoiceClip? {
        // Read before stopping: a stopped recorder reports zero.
        var duration = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            // Dropping the file closes it, so its last packets are on disk before it is read.
            engineFile?.file = nil
            engineFile = nil
            duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        }
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let fileURL else { return nil }
        self.fileURL = nil
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        return QuickVoiceClip(audio: data, duration: duration)
    }

    /// The input node records into an AAC file in its own format, so no conversion runs on
    /// the audio thread.
    private func startEngine(writingTo url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw QuickVoiceStartFailure(step: .engine, code: nil)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let file = try Self.step(.engine) {
            try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                            interleaved: format.isInterleaved)
        }
        let holder = QuickVoiceEngineFile(file)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? holder.file?.write(from: buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            holder.file = nil
            throw QuickVoiceStartFailure(step: .engine, error: error)
        }
        self.engine = engine
        engineFile = holder
    }

    private static func newFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("quick-voice-\(UUID().uuidString).m4a")
    }

    @discardableResult
    private static func step<T>(_ step: QuickVoiceStartFailure.Step, _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch {
            throw QuickVoiceStartFailure(step: step, error: error)
        }
    }
}

/// The engine path's file, held by reference so stopping can drop it (closing it) while the
/// tap's block may still be retained.
final class QuickVoiceEngineFile {
    var file: AVAudioFile?
    init(_ file: AVAudioFile) { self.file = file }
}

/// Where a start stopped, and the system's code: shown on the pill after the usual line and
/// written to the client log, so a refusal on the phone can be read from the box.
struct QuickVoiceStartFailure: LocalizedError, Equatable {
    enum Step: String {
        case category, activate, engine
    }

    let step: Step
    let code: Int?

    init(step: Step, code: Int?) {
        self.step = step
        self.code = code
    }

    init(step: Step, error: Error) {
        self.init(step: step, code: (error as NSError).code)
    }

    var errorDescription: String? {
        let detail = code.map { "\(step.rawValue) \($0)" } ?? step.rawValue
        return String(localized: "Recording could not start.") + " (\(detail))"
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
