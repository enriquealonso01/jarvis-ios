import AVFoundation
import XCTest
@testable import HermesMobile

/// A scripted `AVAudioRecorder`: writes bytes to its file as it "records", appends on resume.
private final class FakeVoiceRecorder: VoiceNoteAudioRecording {
    let url: URL
    var isRecording = false
    var currentTime: TimeInterval = 0
    var isMeteringEnabled = false
    var power: Float = -20
    var recordCalls = 0
    var stopCalls = 0
    var refusesToRecord = false

    init(url: URL) { self.url = url }

    func prepareToRecord() -> Bool { true }

    func record() -> Bool {
        guard !refusesToRecord else { return false }
        recordCalls += 1
        isRecording = true
        // One chunk per recording stretch, appended to the same file.
        let chunk = Data("chunk\(recordCalls);".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(chunk)
            try? handle.close()
        } else {
            try? chunk.write(to: url)
        }
        return true
    }

    func pause() { isRecording = false }
    func stop() { isRecording = false; stopCalls += 1 }
    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { power }
}

/// Records real AAC audio like `AVAudioRecorder`: one `.m4a` kept open across pause and
/// resume, each `record()` stretch appending `segmentSeconds` of a tone (or silence), closed
/// (finalized) on `stop()`.
private final class ToneVoiceRecorder: VoiceNoteAudioRecording {
    static let segmentSeconds = 0.5
    let url: URL
    let amplitude: Float
    var isRecording = false
    var isMeteringEnabled = false
    private(set) var segments = 0
    private var file: AVAudioFile?

    init(url: URL, amplitude: Float) {
        self.url = url
        self.amplitude = amplitude
    }

    var currentTime: TimeInterval { Double(segments) * Self.segmentSeconds }

    func prepareToRecord() -> Bool { true }

    func record() -> Bool {
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: ComposerVoiceNoteRecorder.recordingSettings)
            }
            guard let file else { return false }
            let format = file.processingFormat
            let frames = AVAudioFrameCount(format.sampleRate * Self.segmentSeconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData?[0] else { return false }
            buffer.frameLength = frames
            for index in 0..<Int(frames) {
                channel[index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(format.sampleRate))
            }
            try file.write(from: buffer)
            segments += 1
            isRecording = true
            return true
        } catch {
            return false
        }
    }

    func pause() { isRecording = false }

    func stop() {
        isRecording = false
        file = nil  // closes and finalizes the .m4a
    }

    func updateMeters() {}
    func averagePower(forChannel channelNumber: Int) -> Float { amplitude > 0 ? -6 : -160 }
}

@MainActor
final class ComposerVoiceNoteRecorderTests: XCTestCase {
    private var fakes: [FakeVoiceRecorder] = []
    private var sessionActivations = 0
    private var sessionDeactivations = 0
    private var permission: VoiceNoteMicrophonePermission = .granted
    private var grantsOnRequest = true

    private func makeRecorder() -> ComposerVoiceNoteRecorder {
        ComposerVoiceNoteRecorder(
            recorderFactory: { [unowned self] url in
                let fake = FakeVoiceRecorder(url: url)
                fakes.append(fake)
                return fake
            },
            permissionStatus: { [unowned self] in permission },
            permissionRequester: { [unowned self] in grantsOnRequest },
            audioSession: VoiceNoteAudioSession(
                activate: { [unowned self] in sessionActivations += 1 },
                deactivate: { [unowned self] in sessionDeactivations += 1 }
            ),
            runsTicker: false
        )
    }

    private func advance(_ recorder: ComposerVoiceNoteRecorder, to time: TimeInterval) {
        fakes.last?.currentTime = time
        recorder.tick()
    }

    // MARK: - State machine

    func testHoldStartsUnlockedAndReleaseSends() async throws {
        let recorder = makeRecorder()
        await recorder.begin()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertFalse(recorder.isLocked, "a held note sends on release")
        advance(recorder, to: 2)

        let note = try XCTUnwrap(recorder.finish())
        XCTAssertEqual(note.duration, 2, accuracy: 0.01)
        XCTAssertTrue(VoiceNoteFilename.isVoiceNote(note.filename))
        XCTAssertEqual(String(data: note.data, encoding: .utf8), "chunk1;")
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(sessionDeactivations, 1)
    }

    func testLockThenPauseResumeAppendsToTheSameNote() async throws {
        let recorder = makeRecorder()
        await recorder.begin()
        recorder.lock()
        XCTAssertTrue(recorder.isLocked)
        advance(recorder, to: 1.5)

        recorder.pause()
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertTrue(recorder.isLocked)
        XCTAssertEqual(recorder.elapsed, 1.5, accuracy: 0.01)

        recorder.resume()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(fakes.count, 1, "resume records into the same recorder and file")
        advance(recorder, to: 3)

        let note = try XCTUnwrap(recorder.finish())
        XCTAssertEqual(String(data: note.data, encoding: .utf8), "chunk1;chunk2;", "one file, both stretches")
        XCTAssertEqual(note.duration, 3, accuracy: 0.01)
    }

    func testPausedNoteIsStoppedSoItsFileIsFinalizedOnSend() async throws {
        let recorder = makeRecorder()
        await recorder.begin()
        advance(recorder, to: 2)
        recorder.pause()
        _ = try XCTUnwrap(recorder.finish())
        XCTAssertEqual(fakes.first?.stopCalls, 1, "a paused AVAudioRecorder must be stopped to close the .m4a")
    }

    func testPauseNeverSendsAndCancelDiscards() async {
        let recorder = makeRecorder()
        await recorder.begin()
        advance(recorder, to: 4)
        recorder.pause()
        XCTAssertTrue(recorder.hasNoteInProgress)
        recorder.cancel()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(recorder.isLocked)
        XCTAssertNil(recorder.finish())
        let file = fakes.first?.url
        XCTAssertFalse(file.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    func testInterruptionPausesAndKeepsTheNote() async throws {
        let recorder = makeRecorder()
        await recorder.begin()
        advance(recorder, to: 2)
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        for _ in 0..<50 where recorder.state != .paused { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(recorder.state, .paused, "an interruption pauses, never finishes")
        XCTAssertTrue(recorder.isLocked)
        recorder.resume()
        XCTAssertEqual(recorder.state, .recording)
        advance(recorder, to: 3)
        XCTAssertNotNil(recorder.finish())
    }

    func testTooShortNoteIsDiscarded() async {
        let recorder = makeRecorder()
        await recorder.begin()
        advance(recorder, to: 0.2)
        XCTAssertNil(recorder.finish())
        XCTAssertEqual(recorder.state, .idle)
    }

    func testFirstNoteBehindThePermissionPromptStartsLocked() async {
        permission = .undetermined
        let recorder = makeRecorder()
        await recorder.begin()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertTrue(recorder.isLocked, "the finger left during the prompt; the note waits for Send")
    }

    func testDeniedMicrophoneSaysSo() async {
        permission = .denied
        grantsOnRequest = false
        let recorder = makeRecorder()
        await recorder.begin()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertNotNil(recorder.errorMessage)
    }

    func testRecorderThatWontStartReportsAnError() async {
        let recorder = ComposerVoiceNoteRecorder(
            recorderFactory: { url in
                let fake = FakeVoiceRecorder(url: url)
                fake.refusesToRecord = true
                return fake
            },
            permissionStatus: { .granted },
            permissionRequester: { true },
            audioSession: VoiceNoteAudioSession(activate: {}, deactivate: {}),
            runsTicker: false
        )
        await recorder.begin()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertNotNil(recorder.errorMessage)
    }

    func testLevelsFollowTheInputAndAreCapped() async {
        let recorder = makeRecorder()
        await recorder.begin()
        fakes.last?.power = 0
        for step in 1...(ComposerVoiceNoteRecorder.levelCount + 10) { advance(recorder, to: Double(step) * 0.1) }
        XCTAssertEqual(recorder.levels.count, ComposerVoiceNoteRecorder.levelCount)
        XCTAssertEqual(recorder.levels.last ?? 0, 1, accuracy: 0.001)
        fakes.last?.power = -60
        advance(recorder, to: 100)
        XCTAssertEqual(recorder.levels.last ?? 1, 0, accuracy: 0.001)
    }

    // MARK: - Real audio: pause and resume merge, silence guard

    private func toneRecorder(amplitude: Float) -> ComposerVoiceNoteRecorder {
        ComposerVoiceNoteRecorder(
            recorderFactory: { ToneVoiceRecorder(url: $0, amplitude: amplitude) },
            permissionStatus: { .granted },
            permissionRequester: { true },
            audioSession: VoiceNoteAudioSession(activate: {}, deactivate: {}),
            runsTicker: false
        )
    }

    func testPausedAndResumedSegmentsMakeOneAudibleNote() async throws {
        let recorder = toneRecorder(amplitude: 0.5)
        await recorder.begin()
        recorder.tick()
        recorder.pause()
        recorder.resume()
        recorder.tick()

        let note = try XCTUnwrap(recorder.finish())
        let analysis = try XCTUnwrap(note.analysis, "the merged file decodes")
        XCTAssertEqual(analysis.duration, 2 * ToneVoiceRecorder.segmentSeconds, accuracy: 0.15,
                       "both stretches are in the one file")
        XCTAssertGreaterThan(analysis.peak, 0.3, "the tone survives the pause and resume")
        XCTAssertFalse(analysis.isSilent)
        XCTAssertTrue(note.isUsable)
        XCTAssertTrue(note.diagnostics.contains("segments=2"), note.diagnostics)
    }

    func testSilentNoteIsNotUsable() async throws {
        let recorder = toneRecorder(amplitude: 0)
        await recorder.begin()
        recorder.tick()
        recorder.pause()
        recorder.resume()
        let note = try XCTUnwrap(recorder.finish())
        XCTAssertEqual(note.analysis?.isSilent, true)
        XCTAssertFalse(note.isUsable, "silence is never uploaded")
        XCTAssertFalse(note.diagnostics.contains("decoded=none"), note.diagnostics)
    }

    func testUndecodableFileIsNotUsable() async throws {
        // The scripted recorder writes text, like a header-only or broken container.
        let recorder = makeRecorder()
        await recorder.begin()
        advance(recorder, to: 2)
        let note = try XCTUnwrap(recorder.finish())
        XCTAssertNil(note.analysis)
        XCTAssertFalse(note.isUsable)
        XCTAssertTrue(note.diagnostics.contains("decoded=none"), note.diagnostics)
    }

    func testAnalysisRejectsTooShortClips() {
        XCTAssertFalse(VoiceNoteAudioAnalysis(duration: 0.2, peak: 0.5, rms: 0.2).isUsable)
        XCTAssertTrue(VoiceNoteAudioAnalysis(duration: 1, peak: 0.5, rms: 0.2).isUsable)
        XCTAssertFalse(VoiceNoteAudioAnalysis(duration: 5, peak: 0.0005, rms: 0.0001).isUsable)
    }

    // MARK: - Gesture

    func testSwipeUpLocksAndSlideLeftCancels() {
        typealias G = ComposerVoiceNoteGesture
        XCTAssertEqual(G.dragAction(translation: .zero), .none)
        XCTAssertEqual(G.dragAction(translation: CGSize(width: 0, height: -G.lockTranslationThreshold)), .lock)
        XCTAssertEqual(G.dragAction(translation: CGSize(width: -G.cancelTranslationThreshold, height: 0)), .cancel)
        XCTAssertEqual(G.dragAction(translation: CGSize(width: -40, height: -30)), .none)
        XCTAssertEqual(G.dragAction(translation: CGSize(width: 0, height: 200)), .none, "down never locks")
        XCTAssertEqual(G.dragAction(translation: CGSize(width: 200, height: 0)), .none, "right never cancels")
        // Diagonal: whichever way dominates.
        XCTAssertEqual(G.dragAction(translation: CGSize(width: -150, height: -80)), .cancel)
        XCTAssertEqual(G.dragAction(translation: CGSize(width: -60, height: -120)), .lock)
    }

    func testReleaseSendsAHoldButATapKeepsRecording() {
        typealias G = ComposerVoiceNoteGesture
        XCTAssertEqual(G.releaseAction(isLocked: false, wasCancelled: false, heldFor: 1.2), .send)
        XCTAssertEqual(G.releaseAction(isLocked: false, wasCancelled: false, heldFor: 0.1), .lock)
        XCTAssertEqual(G.releaseAction(isLocked: true, wasCancelled: false, heldFor: 3), .none, "locked: release never sends")
        XCTAssertEqual(G.releaseAction(isLocked: false, wasCancelled: true, heldFor: 3), .none)
        XCTAssertEqual(G.cancelProgress(translationWidth: 0), 0)
        XCTAssertEqual(G.cancelProgress(translationWidth: -G.cancelTranslationThreshold / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(G.cancelProgress(translationWidth: -500), 1)
    }

    // MARK: - Filename

    func testGenerateFilenameIsM4AVoiceNote() {
        let uuid = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let name = VoiceNoteFilename.generate(uuid: uuid)

        XCTAssertTrue(name.hasPrefix("voice-note-"))
        XCTAssertTrue(name.hasSuffix(".m4a"))
        XCTAssertEqual(name, "voice-note-abcdef01.m4a")
        XCTAssertTrue(VoiceNoteFilename.isVoiceNote(name))
    }

    func testIsVoiceNoteRejectsOtherFiles() {
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("photo.jpg"))
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("voice-note-123.wav"))
        XCTAssertFalse(VoiceNoteFilename.isVoiceNote("note.m4a"))
    }
}
