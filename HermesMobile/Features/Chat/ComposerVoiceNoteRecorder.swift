import AVFoundation
import CoreGraphics
import Foundation
import Observation
import OSLog

/// What the voice-note recorder needs from `AVAudioRecorder`, so its state machine runs in
/// unit tests with a scripted recorder (CI simulators have no microphone).
protocol VoiceNoteAudioRecording: AnyObject {
    var isRecording: Bool { get }
    var currentTime: TimeInterval { get }
    var isMeteringEnabled: Bool { get set }
    @discardableResult func prepareToRecord() -> Bool
    func record() -> Bool
    func pause()
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: VoiceNoteAudioRecording {}

/// The microphone permission as the recorder needs it.
enum VoiceNoteMicrophonePermission: Equatable {
    case undetermined, denied, granted

    static var current: VoiceNoteMicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }
}

#if DEBUG
/// Maestro's simulator has no microphone. With the `JarvisFakeMicrophone` default set (the QA
/// lane writes it), Debug builds record a silent stand-in so the voice-note bar's states can be
/// checked end to end. Never in Release builds.
enum QAFakeMicrophone {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "JarvisFakeMicrophone") }

    final class Recorder: VoiceNoteAudioRecording {
        let url: URL
        private var started: Date?
        private var recorded: TimeInterval = 0
        var isMeteringEnabled = false

        init(url: URL) { self.url = url }

        var isRecording: Bool { started != nil }
        var currentTime: TimeInterval { recorded + (started.map { Date().timeIntervalSince($0) } ?? 0) }

        func prepareToRecord() -> Bool { true }

        func record() -> Bool {
            if started == nil { started = Date() }
            if !FileManager.default.fileExists(atPath: url.path) { try? Data(repeating: 0, count: 2048).write(to: url) }
            return true
        }

        func pause() {
            recorded = currentTime
            started = nil
        }

        func stop() { pause() }
        func updateMeters() {}
        func averagePower(forChannel channelNumber: Int) -> Float { Float.random(in: -40 ... -5) }
    }
}
#endif

/// Turns the shared audio session on for recording and off again; injectable for tests.
struct VoiceNoteAudioSession {
    var activate: () throws -> Void
    var deactivate: () -> Void
    /// The session's category, mode, input route and permission, for the app's log.
    var describe: () -> String = { "session=test" }

    static let live = VoiceNoteAudioSession(
        activate: {
            #if DEBUG
            if QAFakeMicrophone.isOn { return }
            #endif
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            // A route left without an input (after a call, a disconnected headset) records
            // silence; fall back to the iPhone's own microphone.
            if session.currentRoute.inputs.isEmpty,
               let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        },
        deactivate: {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        },
        describe: {
            let session = AVAudioSession.sharedInstance()
            let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: "+")
            return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
                + "input=\(inputs.isEmpty ? "none" : inputs) available=\(session.availableInputs?.count ?? 0) "
                + "inputAvailable=\(session.isInputAvailable) rate=\(Int(session.sampleRate)) "
                + "otherAudio=\(session.isOtherAudioPlaying) permission=\(VoiceNoteMicrophonePermission.current)"
        }
    )
}

/// What a finished clip actually holds, measured on the phone before anything is uploaded:
/// a silent or near-empty file is never sent (the box's speech-to-text would return nothing).
struct VoiceNoteAudioAnalysis: Equatable {
    let duration: TimeInterval
    /// Linear peak sample, 0...1.
    let peak: Float
    /// Linear RMS over the whole clip, 0...1.
    let rms: Float

    /// About -54 dBFS: quieter than any speech the microphone picks up.
    static let silencePeak: Float = 0.002
    static let minimumDuration: TimeInterval = 0.3

    var peakDecibels: Float { peak > 0 ? 20 * log10(peak) : -160 }
    var isSilent: Bool { peak < Self.silencePeak }
    var isUsable: Bool { duration >= Self.minimumDuration && !isSilent }

    /// Decodes the file (AAC .m4a, or any format AVAudioFile reads) and measures it; nil when it
    /// can't be read at all (a header-only or unfinished file).
    static func analyze(url: URL) -> VoiceNoteAudioAnalysis? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var peak: Float = 0
        var sumSquares: Double = 0
        var frames: Int64 = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let channel = buffer.floatChannelData?[0] else { break }
            for index in 0..<count {
                let sample = abs(channel[index])
                if sample > peak { peak = sample }
                sumSquares += Double(sample * sample)
            }
            frames += Int64(count)
        }
        guard frames > 0 else { return nil }
        return VoiceNoteAudioAnalysis(duration: Double(frames) / format.sampleRate, peak: peak,
                                      rms: Float((sumSquares / Double(frames)).squareRoot()))
    }
}

/// Records one WhatsApp-style voice note to a temporary `.m4a`/AAC file, distinct from
/// `ComposerVoiceInputController` (on-device dictation). The composer holds one as `@State`.
///
/// States: idle → (requestingPermission) → recording ⇄ paused → idle. `isLocked` says whether a
/// release of the mic still sends (a held, unlocked note) or the note waits for the bar's Send
/// (locked: swiped up, tapped, paused, or started behind the permission prompt). Pause keeps
/// the clip and Resume records into the same file (AVAudioRecorder appends after `pause()`).
/// Nothing is sent or transcribed until `finish()` (Send); an interruption only pauses.
@MainActor
@Observable
final class ComposerVoiceNoteRecorder {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        /// Interrupted (a call, Siri, leaving the app, locking the phone) or paused by the user.
        /// The clip so far is kept; `resume()` continues the same note and `finish()` sends it.
        /// JARVIS never auto-finishes an interrupted note.
        case paused
    }

    struct RecordedVoiceNote {
        let data: Data
        let filename: String
        let duration: TimeInterval
        /// The decoded file's real length and level; nil when it couldn't be decoded.
        var analysis: VoiceNoteAudioAnalysis?
        /// One line for the app's log (requirement 9): session, route, file and levels.
        var diagnostics = ""

        /// Worth uploading: decodable, long enough, and not silent.
        var isUsable: Bool { analysis?.isUsable ?? false }
    }

    /// Hard cap on a single clip. AAC mono at ~32 kbps stays far under the 20 MB
    /// upload limit even at five minutes (~1.2 MB), so this bounds UX, not size.
    static let maximumDuration: TimeInterval = 5 * 60
    /// Clips shorter than this are treated as accidental taps and discarded.
    static let minimumDuration: TimeInterval = 0.5
    /// Waveform samples kept for the live bar (newest last).
    static let levelCount = 40

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?
    /// Release no longer sends: the note waits for Send in the bar.
    private(set) var isLocked = false
    /// Recent input levels, 0...1, for the live waveform.
    private(set) var levels: [CGFloat] = []

    @ObservationIgnored private var recorder: VoiceNoteAudioRecording?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var didActivateSession = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var lockWhenStarted = false
    /// Diagnostics: recording stretches (1 + resumes), the loudest meter reading, and the
    /// session as it was when recording started.
    @ObservationIgnored private var segments = 0
    @ObservationIgnored private var meterPeak: Float = -160
    @ObservationIgnored private var startDescription = ""
    @ObservationIgnored private let recorderFactory: (URL) throws -> VoiceNoteAudioRecording
    @ObservationIgnored private let permissionStatus: () -> VoiceNoteMicrophonePermission
    @ObservationIgnored private let permissionRequester: () async -> Bool
    @ObservationIgnored private let audioSession: VoiceNoteAudioSession
    @ObservationIgnored private let runsTicker: Bool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "HermesMobile",
        category: "VoiceNote"
    )

    init(
        recorderFactory: @escaping (URL) throws -> VoiceNoteAudioRecording = {
            #if DEBUG
            if QAFakeMicrophone.isOn { return QAFakeMicrophone.Recorder(url: $0) }
            #endif
            return try AVAudioRecorder(url: $0, settings: ComposerVoiceNoteRecorder.recordingSettings)
        },
        permissionStatus: @escaping () -> VoiceNoteMicrophonePermission = {
            #if DEBUG
            if QAFakeMicrophone.isOn { return .granted }
            #endif
            return VoiceNoteMicrophonePermission.current
        },
        permissionRequester: @escaping () async -> Bool = { await ComposerVoiceMicrophonePermissionRequester.request() },
        audioSession: VoiceNoteAudioSession = .live,
        runsTicker: Bool = true
    ) {
        self.recorderFactory = recorderFactory
        self.permissionStatus = permissionStatus
        self.permissionRequester = permissionRequester
        self.audioSession = audioSession
        self.runsTicker = runsTicker
    }

    var isRecording: Bool { state == .recording }
    var isPaused: Bool { state == .paused }
    /// Recording or paused: a note is in progress and the recording bar shows.
    var hasNoteInProgress: Bool { state == .recording || state == .paused }
    var isRequestingPermission: Bool { state == .requestingPermission }
    var hasReachedMaximumDuration: Bool { elapsed >= Self.maximumDuration }

    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]

    // MARK: - Lifecycle

    /// Starts a note: asks for the microphone if needed, then records to a temporary `.m4a`.
    /// `locked` starts it hands-free. A note that had to wait for the permission prompt starts
    /// locked too: the finger that held the mic has left the screen by then.
    func begin(locked: Bool = false) async {
        guard state == .idle else { return }
        errorMessage = nil
        elapsed = 0
        levels = []
        isLocked = locked
        lockWhenStarted = false
        state = .requestingPermission

        let wasUndetermined = permissionStatus() == .undetermined
        let granted = permissionStatus() == .granted ? true : await permissionRequester()
        // The state can change while we await the system prompt (e.g. the view
        // disappeared and called `cancel()`); bail rather than starting late.
        guard state == .requestingPermission else { return }
        guard granted else {
            fail(String(localized: "Microphone access is off. Turn it on in Settings > JARVIS to record voice notes."))
            return
        }

        do {
            try startRecording()
            state = .recording
            if wasUndetermined || lockWhenStarted { isLocked = true }
            lockWhenStarted = false
            startTicker()
            logger.info("Voice note recording started")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Swipe up while holding (or a tap): hands-free from here on.
    func lock() {
        switch state {
        case .recording, .paused: isLocked = true
        case .requestingPermission: lockWhenStarted = true
        case .idle: break
        }
    }

    /// Stops recording and returns the finished clip (Send), or nil if it was too short,
    /// failed to read, or nothing was recording. Always restores the audio session.
    func finish() -> RecordedVoiceNote? {
        guard state == .recording || state == .paused, let recorder, let fileURL else {
            cancel()
            return nil
        }

        let duration = max(recorder.isRecording ? recorder.currentTime : 0, elapsed)
        stopRecorder()

        guard duration >= Self.minimumDuration else {
            discardFile()
            teardownSession()
            resetState()
            return nil
        }

        let data = try? Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let analysis = VoiceNoteAudioAnalysis.analyze(url: fileURL)
        let diagnostics = finishDiagnostics(fileBytes: data?.count ?? 0, duration: duration, analysis: analysis)
        discardFile()
        teardownSession()
        resetState()

        guard let data, !data.isEmpty else {
            errorMessage = String(localized: "Couldn't read the recorded voice note. Try again.")
            JarvisClientLog.record("voice", "unreadable note: " + diagnostics)
            return nil
        }
        return RecordedVoiceNote(data: data, filename: filename, duration: duration,
                                 analysis: analysis, diagnostics: diagnostics)
    }

    /// Says why a finished note was not sent (silent, too short, undecodable).
    func reject(_ message: String) {
        errorMessage = message
    }

    private func finishDiagnostics(fileBytes: Int, duration: TimeInterval, analysis: VoiceNoteAudioAnalysis?) -> String {
        let measured = analysis.map {
            String(format: "decoded=%.2fs peak=%.1fdB rms=%.4f", $0.duration, $0.peakDecibels, $0.rms)
        } ?? "decoded=none"
        return String(format: "bytes=%ld elapsed=%.2fs segments=%ld meterPeak=%.1fdB ", fileBytes, duration,
                      segments, meterPeak) + measured + " | start: " + startDescription
    }

    /// Pauses the note, keeping what was recorded. The bar's Pause, an audio interruption and
    /// leaving the foreground all land here; a paused note is locked and waits for Resume,
    /// Send or Delete. Never sends or transcribes.
    func pause() {
        guard state == .recording, let recorder else { return }
        elapsed = max(elapsed, recorder.currentTime)
        if recorder.isRecording { recorder.pause() }
        stopTicker()
        ComposerAudioCaptureState.shared.setCapturing(false)
        teardownSession()
        isLocked = true
        state = .paused
        logger.info("Voice note paused")
    }

    /// Continues the same note after a pause: AVAudioRecorder appends to the same file.
    func resume() {
        guard state == .paused, let recorder else { return }
        do {
            try audioSession.activate()
            didActivateSession = true
            guard recorder.record() else { throw ComposerVoiceNoteRecorderError.couldNotStart }
            segments += 1
            ComposerAudioCaptureState.shared.setCapturing(true)
            state = .recording
            startTicker()
            logger.info("Voice note resumed")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops and discards the recording without producing a clip (slide to cancel, Delete).
    func cancel() {
        stopRecorder()
        discardFile()
        teardownSession()
        resetState()
    }

    /// One ticker step: elapsed time and a waveform sample. Public for tests.
    func tick() {
        guard let recorder, recorder.isRecording else { return }
        elapsed = max(elapsed, recorder.currentTime)
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        meterPeak = max(meterPeak, power)
        // -50 dB and quieter reads as silence; 0 dB is full scale.
        let level = CGFloat(max(0, min(1, (power + 50) / 50)))
        levels.append(level)
        if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
    }

    // MARK: - Recording internals

    private func startRecording() throws {
        try audioSession.activate()
        didActivateSession = true

        let url = Self.makeTemporaryFileURL()
        let recorder = try recorderFactory(url)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw ComposerVoiceNoteRecorderError.couldNotStart
        }
        self.recorder = recorder
        self.fileURL = url
        segments = 1
        meterPeak = -160
        startDescription = audioSession.describe()
        JarvisClientLog.record("voice", "recording started: " + startDescription)
        ComposerAudioCaptureState.shared.setCapturing(true)
        observeInterruptions()
    }

    /// A phone call, FaceTime, Siri or an alarm takes the microphone: pause, never finish.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    private func stopRecorder() {
        if recorder?.isRecording == true || state == .paused {
            recorder?.stop()
        }
        recorder = nil
        ComposerAudioCaptureState.shared.setCapturing(false)
        stopTicker()
    }

    private func discardFile() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }

    private func teardownSession() {
        guard didActivateSession else { return }
        audioSession.deactivate()
        didActivateSession = false
    }

    private func resetState() {
        state = .idle
        elapsed = 0
        isLocked = false
        lockWhenStarted = false
        levels = []
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    private func fail(_ message: String) {
        cancel()
        errorMessage = message
        JarvisClientLog.record("voice", "recording failed: \(message) | \(audioSession.describe())")
        logger.error("Voice note recording failed")
    }

    // MARK: - Ticker

    private func startTicker() {
        stopTicker()
        guard runsTicker else { return }
        // `.common` so the timer keeps firing while the transcript scrolls.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    static func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(VoiceNoteFilename.generate())
    }

    deinit {
        ticker?.invalidate()
    }
}

enum ComposerVoiceNoteRecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return String(localized: "Couldn't start recording. Try again.")
        }
    }
}

/// Generates collision-resistant `.m4a` names for recorded voice notes. The
/// 8-char suffix mirrors the attachment coordinator's uniquing so two quick notes
/// don't clash on upload, and the `.m4a` extension makes the inline player treat
/// the clip as audio even when the server reports a generic MIME type.
enum VoiceNoteFilename {
    static func generate(uuid: UUID = UUID()) -> String {
        let suffix = uuid.uuidString.prefix(8).lowercased()
        return "voice-note-\(suffix).m4a"
    }

    static func isVoiceNote(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasPrefix("voice-note-") && lower.hasSuffix(".m4a")
    }

    /// A sent message's voice note, by its chip's name or path: on a Hermes host `file.attach`
    /// stores it as `<uuid>-voice-note-<suffix>.m4a`.
    static func isVoiceNoteAttachment(_ nameOrPath: String?) -> Bool {
        guard let nameOrPath else { return false }
        let last = URL(fileURLWithPath: nameOrPath).lastPathComponent.lowercased()
        return last.hasSuffix(".m4a") && last.contains("voice-note-")
    }
}

/// JARVIS voice-note preferences.
enum JarvisVoiceNoteSettings {
    /// A tap on the composer mic records a hands-free voice note (default); off, it dictates.
    static let tapRecordsKey = "jarvis.voiceNote.tapRecords"
}

/// Pure decisions for the WhatsApp-style mic gesture, kept out of the view so the thresholds
/// are unit-testable. Press and hold records at once; swipe up locks (hands-free); slide left
/// cancels; a release while unlocked sends; a quick tap leaves the note recording, locked.
enum ComposerVoiceNoteGesture {
    /// With "Tap Mic for Voice Note" off, a press must be held this long before it records,
    /// so a quicker tap still dictates (Hermex's behaviour).
    static let holdActivationDelay: TimeInterval = 0.3
    /// A release sooner than this after touch-down is a tap, not a hold-and-release.
    static let tapDuration: TimeInterval = 0.35
    /// Swiping up this far while holding locks the note.
    static let lockTranslationThreshold: CGFloat = 70
    /// Sliding left this far while holding cancels the note.
    static let cancelTranslationThreshold: CGFloat = 110

    enum DragAction: Equatable { case none, lock, cancel }

    /// What a drag while holding does: mostly-left past the threshold cancels, mostly-up
    /// past the threshold locks.
    static func dragAction(translation: CGSize) -> DragAction {
        let left = -translation.width, up = -translation.height
        if left >= cancelTranslationThreshold && left > up { return .cancel }
        if up >= lockTranslationThreshold && up >= left { return .lock }
        return .none
    }

    enum ReleaseAction: Equatable {
        /// An unlocked hold ended: send the note.
        case send
        /// A quick tap: keep recording, hands-free (locked).
        case lock
        /// Locked or already cancelled: the release does nothing.
        case none
    }

    static func releaseAction(isLocked: Bool, wasCancelled: Bool, heldFor: TimeInterval) -> ReleaseAction {
        if wasCancelled || isLocked { return .none }
        return heldFor < tapDuration ? .lock : .send
    }

    /// How far the slide-to-cancel has gone, 0...1, for the hint.
    static func cancelProgress(translationWidth: CGFloat) -> CGFloat {
        max(0, min(1, -translationWidth / cancelTranslationThreshold))
    }
}
