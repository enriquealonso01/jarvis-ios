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

    private final class Recording: QuickVoiceRecording {
        var startError: Error?
        var clip: Data?
        private(set) var starts = 0
        private(set) var stops = 0

        func start() throws {
            if let startError { throw startError }
            starts += 1
        }

        func stop() -> Data? {
            stops += 1
            return clip
        }
    }

    private var chatURL: URL { URL(string: "hermes-agent://session?id=key-1")! }

    func testToggleStartsRecordingThenStopsSendsAndReturnsToIdle() async {
        let clip = Data("clip".utf8)
        let recording = Recording()
        recording.clip = clip
        var delivered: [Data] = []
        var outcome: QuickVoiceController.Outcome?
        let controller = QuickVoiceController(makeRecorder: { recording }) { audio in
            delivered.append(audio)
            outcome = .sent(self.chatURL)
            return .sent(self.chatURL)
        }

        XCTAssertTrue(await controller.toggle())
        XCTAssertEqual(controller.phase, .recording, "The first press records")
        XCTAssertEqual(recording.starts, 1)

        XCTAssertTrue(await controller.toggle())
        XCTAssertEqual(delivered, [clip], "The second press sends exactly the recorded clip")
        XCTAssertEqual(recording.stops, 1)
        XCTAssertEqual(controller.phase, .idle, "A finished send returns the toggle to idle")
    }

    func testARefusedStartReportsFailureAndReturnsToIdle() async {
        let recording = Recording()
        recording.startError = QuickVoiceError.microphoneOff
        let controller = QuickVoiceController(makeRecorder: { recording }) { _ in
            XCTFail("Nothing is sent when recording never started")
            return .failed("unreachable")
        }

        XCTAssertFalse(await controller.toggle(), "A mic permission failure refuses the start")
        XCTAssertEqual(controller.phase, .idle)
        // The next press is a fresh start, not a stop of a recording that never was.
        recording.startError = nil
        recording.clip = Data("clip".utf8)
        XCTAssertTrue(await controller.toggle())
        XCTAssertEqual(controller.phase, .recording)
    }

    func testAnEmptyClipFailsWithoutSending() async {
        let recording = Recording()
        recording.clip = Data()
        let controller = QuickVoiceController(makeRecorder: { recording }) { _ in
            XCTFail("An empty clip is never delivered")
            return .failed("unreachable")
        }

        XCTAssertTrue(await controller.toggle())
        await controller.toggle()
        XCTAssertEqual(controller.phase, .idle, "The empty clip ends where it failed, back at idle")
    }

    func testAFailedSendStillReturnsTheToggleToIdle() async {
        let recording = Recording()
        recording.clip = Data("clip".utf8)
        let controller = QuickVoiceController(makeRecorder: { recording }) { _ in .failed("no network") }

        XCTAssertTrue(await controller.toggle())
        XCTAssertTrue(await controller.toggle())
        XCTAssertEqual(controller.phase, .idle)
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
                                         socket.reply = { [weak socket, weak host] request in
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

extension BotSocketHost {
    /// The private script entry `BotSocketHost.connection` wires into its sockets,
    /// exposed for a test that builds its own connection around the same host.
    func answerForTest(_ request: BotJSON, on socket: BotScriptedSocket?) -> BotJSON {
        Self.answerForTest(request, on: socket)
    }
}
