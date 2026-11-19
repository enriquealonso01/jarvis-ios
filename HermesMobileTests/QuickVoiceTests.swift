import XCTest
@testable import HermesMobile

/// Quick Voice: the Action button's toggle state machine (`QuickVoiceController`) and
/// the voice-note send path (`QuickVoiceSender`), scripted at the Hermes host's HTTP
/// and socket fixtures exactly as a chat's own tests script it.
@MainActor final class QuickVoiceTests: XCTestCase {
    override func tearDown() {
        HermesHostFixture.reset()
        JarvisBotRouter.testHook = nil
        super.tearDown()
    }

    // MARK: - Toggle state machine

    /// What the pill and the recorder did, in order, so a test can check which came first.
    private final class Events {
        var log: [String] = []
    }

    private final class Recording: QuickVoiceRecording {
        let events: Events
        var startError: Error?
        var clip: QuickVoiceClip?
        private(set) var starts = 0
        private(set) var stops = 0

        init(_ events: Events, clip: QuickVoiceClip? = nil) {
            self.events = events
            self.clip = clip
        }

        func start() throws {
            if let startError { throw startError }
            starts += 1
            events.log.append("record")
        }

        func stop() -> QuickVoiceClip? {
            stops += 1
            events.log.append("stop")
            return clip
        }
    }

    @MainActor private final class Pill: QuickVoicePill {
        let events: Events
        /// False plays a system that refuses the Live Activity (Live Activities off).
        var allowed = true
        private(set) var lines: [(QuickVoiceActivityAttributes.Phase, String)] = []
        private(set) var destination: URL?

        init(_ events: Events) { self.events = events }

        func clearLeftovers() async { events.log.append("clear") }

        func show(_ phase: QuickVoiceActivityAttributes.Phase, message: String) -> Bool {
            guard allowed else { return false }
            events.log.append("show")
            lines.append((phase, message))
            return true
        }

        func update(_ phase: QuickVoiceActivityAttributes.Phase, message: String, destinationURL: URL?) async {
            lines.append((phase, message))
            destination = destinationURL
        }

        func finish() async { events.log.append("finish") }

        var phases: [QuickVoiceActivityAttributes.Phase] { lines.map(\.0) }
        var lastLine: String? { lines.last?.1 }
    }

    private var chatURL: URL { URL(string: "hermes-agent://session?id=key-1")! }
    private let note = QuickVoiceClip(audio: Data("clip".utf8), duration: 4)

    func testThePillGoesUpBeforeRecordingAndTheNextPressSendsInTheBackground() async {
        let events = Events()
        let recording = Recording(events, clip: note)
        let pill = Pill(events)
        var delivered: [Data] = []
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { audio in
            delivered.append(audio)
            return .sent(self.chatURL)
        }, pill: pill)

        let first = await controller.toggle()
        XCTAssertEqual(first, .recording, "The first press records")
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(events.log, ["clear", "show", "record"],
                       "Leftover pills go, then the pill goes up, and only then the recorder starts: "
                       + "iOS stops a background recording that has no Live Activity")

        let second = await controller.toggle()
        XCTAssertEqual(second, .sending, "The second press returns once the clip is stopped")
        await controller.sendTask?.value
        XCTAssertEqual(delivered, [note.audio], "The second press sends exactly the recorded clip")
        XCTAssertEqual(recording.stops, 1)
        XCTAssertEqual(pill.phases, [.recording, .sending, .done])
        XCTAssertEqual(pill.destination, chatURL, "The finished pill opens the new chat")
        XCTAssertEqual(events.log.last, "finish")
        XCTAssertEqual(controller.phase, .idle, "A finished send returns the toggle to idle")
    }

    func testWithoutAPillNothingRecordsAndThePressSaysWhy() async {
        let events = Events()
        let recording = Recording(events, clip: note)
        let pill = Pill(events)
        pill.allowed = false
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { _ in
            XCTFail("Nothing is sent when nothing was recorded")
            return .failed("unreachable")
        }, pill: pill)

        let press = await controller.toggle()
        guard case .refused(let reason) = press else { return XCTFail("A press with no pill is refused, got \(press)") }
        XCTAssertFalse(reason.isEmpty, "The refusal carries the reason the system shows instead of its check mark")
        XCTAssertEqual(recording.starts, 0, "No pill, no recording")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAMicrophoneRefusalShowsOnThePillAndTheNextPressStartsAgain() async {
        let events = Events()
        let recording = Recording(events, clip: note)
        recording.startError = QuickVoiceError.microphoneOff
        let pill = Pill(events)
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { _ in
            XCTFail("Nothing is sent when recording never started")
            return .failed("unreachable")
        }, pill: pill)

        let refused = await controller.toggle()
        XCTAssertEqual(refused, .notSent, "A mic permission failure is shown on the pill")
        XCTAssertEqual(pill.phases.last, .failed)
        XCTAssertEqual(pill.lastLine, QuickVoiceError.microphoneOff.errorDescription)
        XCTAssertEqual(controller.phase, .idle)
        // The next press is a fresh start, not a stop of a recording that never was.
        recording.startError = nil
        let restarted = await controller.toggle()
        XCTAssertEqual(restarted, .recording)
        XCTAssertEqual(controller.phase, .recording)
    }

    func testAnEmptyClipIsNotSent() async {
        let events = Events()
        let recording = Recording(events, clip: QuickVoiceClip(audio: Data(), duration: 3))
        let pill = Pill(events)
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { _ in
            XCTFail("An empty clip is never delivered")
            return .failed("unreachable")
        }, pill: pill)

        let first = await controller.toggle()
        XCTAssertEqual(first, .recording)
        let second = await controller.toggle()
        XCTAssertEqual(second, .notSent)
        XCTAssertEqual(pill.phases.last, .failed)
        XCTAssertEqual(controller.phase, .idle, "The empty clip ends where it failed, back at idle")
    }

    func testADoublePressIsTooShortToSend() async {
        let events = Events()
        let recording = Recording(events, clip: QuickVoiceClip(audio: Data("clip".utf8), duration: 0.4))
        let pill = Pill(events)
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { _ in
            XCTFail("A clip under a second is a misfire, never a note")
            return .failed("unreachable")
        }, pill: pill)

        await controller.toggle()
        let second = await controller.toggle()
        XCTAssertEqual(second, .notSent)
        XCTAssertEqual(pill.phases.last, .failed)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAPressWhileTheNoteSendsIsBusy() async {
        let events = Events()
        let recording = Recording(events, clip: note)
        let pill = Pill(events)
        var release: CheckedContinuation<Void, Never>?
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { _ in
            await withCheckedContinuation { release = $0 }
            return .sent(self.chatURL)
        }, pill: pill)

        await controller.toggle()
        let second = await controller.toggle()
        XCTAssertEqual(second, .sending)
        let third = await controller.toggle()
        XCTAssertEqual(third, .busy, "A press during the send neither starts nor stops anything")
        XCTAssertEqual(recording.starts, 1)
        while release == nil { await Task.yield() }
        release?.resume()
        await controller.sendTask?.value
        XCTAssertEqual(controller.phase, .idle)
        let fourth = await controller.toggle()
        XCTAssertEqual(fourth, .recording, "Once the send ends the next press records again")
    }

    func testAFailedSendShowsItsReasonAndReturnsTheToggleToIdle() async {
        let events = Events()
        let recording = Recording(events, clip: note)
        let pill = Pill(events)
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { _ in .failed("no network") },
                                              pill: pill)

        await controller.toggle()
        let second = await controller.toggle()
        XCTAssertEqual(second, .sending)
        await controller.sendTask?.value
        XCTAssertEqual(pill.phases.last, .failed)
        XCTAssertEqual(pill.lastLine, "no network")
        XCTAssertEqual(controller.phase, .idle)
    }

    func testEveryStartClearsLeftoverPills() async {
        let events = Events()
        let recording = Recording(events, clip: note)
        let pill = Pill(events)
        let controller = QuickVoiceController(makeRecorder: { recording }, deliver: { _ in .sent(self.chatURL) },
                                              pill: pill)

        await controller.toggle()
        await controller.toggle()
        await controller.sendTask?.value
        await controller.toggle()
        XCTAssertEqual(events.log.filter { $0 == "clear" }.count, 2,
                       "Each new recording first ends the pill the last one left on screen")
    }

    // MARK: - The send path (transcribe → route → new chat → 🎤 prompt)

    private let server = URL(string: "https://jarvis.test")!

    private func connection() -> BotConnection {
        BotConnection(id: UUID(), name: "JARVIS", address: server, username: "enrique",
                      password: "secret", hermesVersion: nil, installID: nil, headers: nil, oauth: nil)
    }

    /// A connection whose HTTP host answers the password gate and one transcribe, and
    /// whose socket scripts the gateway: `session.create` then `prompt.submit`.
    private func fixture(transcript: String?, route: JarvisBotRoute?,
                         createdProfile: @escaping (String?) -> Void,
                         submittedText: @escaping (String?) -> Void) async -> HermesConnection {
        let host = BotSocketHost()
        host.always("session.create", .init(result: .object([
            "stored_session_id": .string("key-1"), "session_id": .string("runtime-1")])))
        host.always("prompt.submit", .init(result: .object(["status": .string("queued")])))
        let configuration = HermesHostFixture.configuration { request in
            guard request.url?.path == "/api/audio/transcribe" else { return nil }
            guard let transcript else { return .json(200, .object(["ok": .bool(true)])) }
            return .json(200, .object(["ok": .bool(true), "transcript": .string(transcript)]))
        }
        let record = connection()
        let wired = HermesConnection(connection: record, configuration: configuration,
                                     gateway: .init(rpcDeadline: .seconds(5), socketFactory: { _ in
                                         let socket = BotScriptedSocket()
                                         socket.reply = { [weak socket, host] request in
                                             let method = request["method"].text ?? ""
                                             if method == "session.create" {
                                                 createdProfile(request["params"]["profile"].text)
                                             }
                                             if method == "prompt.submit" {
                                                 submittedText(request["params"]["text"].text)
                                             }
                                             return host.answerForTest(request, on: socket)
                                         }
                                         return socket
                                     }))
        // Bot routing never leaves the test: the hook answers for `/bridge/route`.
        JarvisBotRouter.testHook = { _, _ in route }
        return wired
    }

    func testASentNoteOpensANewChatWithTheMicMarker() async {
        let sent = XCTestExpectation(description: "prompt.submit went out")
        let connection = await fixture(transcript: "ship the branch",
                                       route: JarvisBotRoute(profile: "ios-builder", confidence: 0.9,
                                                             reason: nil, title: "iOS Builder"),
                                       createdProfile: { profile in
                                           XCTAssertEqual(profile, "ios-builder",
                                                          "A routed note opens the Bot's chat, not general")
                                       },
                                       submittedText: { text in
                                           XCTAssertEqual(text, "🎤 ship the branch",
                                                          "The prompt carries the transcript behind the mic marker")
                                           sent.fulfill()
                                       })
        let outcome = await QuickVoiceSender.deliver(Data("clip".utf8), profile: "default",
                                                     server: server, saved: self.connection(),
                                                     connection: connection)
        guard case .sent(let url) = outcome else { return XCTFail("The note should have been sent") }
        XCTAssertEqual(url.host, "session", "The tap target is a session deep link")
        XCTAssertTrue(url.query?.contains("id=key-1") == true)
        await fulfillment(of: [sent], timeout: 5)
    }

    func testANoteTheBoxDoesNotRouteStaysGeneral() async {
        let created = XCTestExpectation(description: "session.create went out")
        let connection = await fixture(transcript: "hello",
                                       route: JarvisBotRoute(profile: "general", confidence: 0.4,
                                                             reason: nil, title: nil),
                                       createdProfile: { profile in
                                           XCTAssertEqual(profile, "default",
                                                          "A general or low-confidence route keeps the chat general")
                                           created.fulfill()
                                       },
                                       submittedText: { text in
                                           XCTAssertEqual(text, "🎤 hello")
                                       })
        let outcome = await QuickVoiceSender.deliver(Data("clip".utf8), profile: "default",
                                                     server: server, saved: self.connection(),
                                                     connection: connection)
        guard case .sent = outcome else { return XCTFail("The note should have been sent") }
        await fulfillment(of: [created], timeout: 5)
    }

    func testSilenceIsNotSent() async {
        let connection = await fixture(transcript: nil, route: nil,
                                       createdProfile: { _ in XCTFail("Silence opens no chat") },
                                       submittedText: { _ in XCTFail("Silence submits no prompt") })
        let outcome = await QuickVoiceSender.deliver(Data("clip".utf8), profile: "default",
                                                     server: server, saved: self.connection(),
                                                     connection: connection)
        guard case .failed = outcome else { return XCTFail("An empty transcript is a failure") }
    }

    // MARK: - Transcription reply reading

    func testTranscriptionReplyReading() throws {
        let words = #"{"ok":true,"transcript":"  ship it "}"#
        XCTAssertEqual(try QuickVoiceTranscription.transcript(Data(words.utf8), 200), "ship it")
        // A 2xx without words is silence, not an error.
        XCTAssertEqual(try QuickVoiceTranscription.transcript(Data(#"{"ok":true}"#.utf8), 200), "")
        // A provider failure the host reports on a 2xx throws.
        XCTAssertThrowsError(try QuickVoiceTranscription.transcript(
            Data(#"{"ok":false,"detail":"provider down"}"#.utf8), 200))
        // A proxy in front of the host throws the connection's own failure.
        XCTAssertThrowsError(try QuickVoiceTranscription.transcript(Data("".utf8), 502))
    }
}
