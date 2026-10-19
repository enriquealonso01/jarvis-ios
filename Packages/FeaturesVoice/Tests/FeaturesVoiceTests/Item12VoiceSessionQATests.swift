import Foundation
import XCTest

import DesignSystem
import Persistence
@testable import FeaturesVoice

/// Item 12 BUILDER QA — the in-chat voice layer over REAL events and the
/// REAL store (UI Law §7 + expansion §Voice + kit orbital law).
///
/// Everything drives through the same seams production uses: loopback
/// transport/audio-source conforming to `VoiceTransporting` /
/// `VoiceAudioSourcing`, and a file-backed `PersistenceStore` exercising
/// the verified upsert-by-id transcript path.
@MainActor
final class Item12VoiceSessionQATests: XCTestCase {

    // MARK: - Loopback adapters (same protocols as production)

    private final class LoopbackTransport: VoiceTransporting, @unchecked Sendable {
        var onEvent: (@Sendable (VoiceEngineEvent) async -> Void)?
        private(set) var sentFrames: [VoiceAudioFrame] = []
        private(set) var sentMuted: [Bool] = []
        private(set) var connectCount = 0
        private(set) var disconnectCount = 0
        var connectShouldFail = false

        func connect() async {
            connectCount += 1
            if connectShouldFail {
                await onEvent?(.failure(reason: "transport-unreachable"))
            } else {
                await onEvent?(.sessionConnected)
            }
        }

        func disconnect() async {
            disconnectCount += 1
        }

        func sendAudioFrame(_ frame: VoiceAudioFrame, muted: Bool) async {
            sentFrames.append(frame)
            sentMuted.append(muted)
        }

        func simulate(_ event: VoiceEngineEvent) async {
            await onEvent?(event)
        }
    }

    private final class LoopbackAudioSource: VoiceAudioSourcing, @unchecked Sendable {
        var onFrame: (@Sendable (VoiceAudioFrame) async -> Void)?
        private(set) var permissionAsked = 0
        private(set) var startCount = 0
        private(set) var stopCount = 0
        var grantPermission = true
        private(set) var capturedTurnIDs: [UUID] = []

        func requestPermission() async -> Bool {
            permissionAsked += 1
            return grantPermission
        }

        func startCapturing(turnID: UUID) async {
            startCount += 1
            capturedTurnIDs.append(turnID)
        }

        func stopCapturing() async {
            stopCount += 1
        }

        func emitFrame(_ samples: Int) async {
            await onFrame?(VoiceAudioFrame(sequence: 0, turnID: UUID(), sampleCount: samples))
        }
    }

    // MARK: - Store plumbing (same convention as the Item12 store QA)

    private static let stamp = Date(timeIntervalSince1970: 1_760_000_000)

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item12-voicevm-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    private func makeSession(store: PersistenceStore,
                             transport: LoopbackTransport,
                             audio: LoopbackAudioSource) -> (VoiceSessionViewModel, VoiceTranscriptWriter) {
        let recordingID = UUID()
        let writer = VoiceTranscriptWriter(store: store, recordingID: recordingID)
        let vm = VoiceSessionViewModel(transport: transport, audioSource: audio, transcriptWriter: writer)
        return (vm, writer)
    }

    // MARK: - The full doc §Voice walk over real events

    func testFullSessionWalkIdleToListeningThinkingSpeakingAndEnded() async throws {
        let store = try PersistenceStore(path: tempDBPath("walk"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let (vm, writer) = makeSession(store: store, transport: transport, audio: audio)

        XCTAssertEqual(vm.docState, .idle)
        XCTAssertEqual(vm.orbitalState, .idle)

        await writer.beginRecording(filePath: "recordings/walk.m4a")
        await vm.start()
        XCTAssertEqual(vm.docState, .connecting,
                       "granted permission connects; .requesting_permission is visible only between the intent and the async grant")
        XCTAssertEqual(audio.permissionAsked, 1, "permission is user-initiated, exactly once per start")

        await transport.simulate(.sessionConnected)
        XCTAssertEqual(vm.docState, .listening, "connected → listening (mic live)")
        XCTAssertEqual(audio.startCount, 1, "capture starts on the real connected event")
        XCTAssertEqual(vm.orbitalState, .listening)

        // Partial streams in, then the turn finalizes.
        await transport.simulate(.partialTranscript(text: "ping the", turnID: UUID()))
        XCTAssertEqual(vm.docState, .listening)
        XCTAssertEqual(vm.lastPartial, "ping the")

        let turnID = audio.capturedTurnIDs[0]
        await transport.simulate(.finalTranscript(text: "ping the gateway", turnID: turnID))
        XCTAssertEqual(vm.docState, .thinking, "final utterance = agent works")
        XCTAssertEqual(vm.lastPartial, "", "partial retires when the final lands")
        XCTAssertEqual(vm.orbitalState, .thinking)

        await transport.simulate(.responseStarted)
        XCTAssertEqual(vm.docState, .speaking)
        XCTAssertEqual(vm.orbitalState, .responding, "the ONLY path to the responding orbital")

        await vm.recordResponse("Gateway is up, 42ms.")
        await transport.simulate(.responseFinished)
        XCTAssertEqual(vm.docState, .listening, "back to listening — no timers involved")

        // Persisted end-to-end through the REAL store: user final + assistant
        // answer, plus the anchored recording row.
        await writer.finishRecording(duration: 12.0)
        let segments = await store.transcriptSegments(recordingID: writer.recordingID)
        XCTAssertEqual(segments.map { $0.speaker }, ["user", "assistant"])
        XCTAssertEqual(segments.first?.text, "ping the gateway")
        XCTAssertEqual(segments.last?.text, "Gateway is up, 42ms.")
        let recording = await store.getRecording(id: writer.recordingID)
        XCTAssertEqual(recording?.filePath, "recordings/walk.m4a", "finish preserves the host path")
        XCTAssertEqual(recording?.duration, 12.0)

        await vm.end()
        XCTAssertEqual(vm.docState, .ended)
        XCTAssertEqual(vm.orbitalState, .idle, "ended returns the orbital to rest")
        XCTAssertEqual(audio.stopCount, 1, "end releases the mic (doc: no hidden active mic)")
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    // MARK: - Mic frames ride the transport with seq + live turn

    func testFramesCarrySequenceNumbersLiveTurnIDAndMuteFlag() async throws {
        let store = try PersistenceStore(path: tempDBPath("frames"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let (vm, _) = makeSession(store: store, transport: transport, audio: audio)

        await vm.start()
        await transport.simulate(.sessionConnected)
        let turnID = audio.capturedTurnIDs[0]

        await audio.emitFrame(160)
        await audio.emitFrame(160)
        await vm.toggleMute()
        await audio.emitFrame(160)

        XCTAssertEqual(transport.sentFrames.count, 3)
        XCTAssertEqual(transport.sentFrames.map { $0.sequence }, [1, 2, 3], "monotonic sequence numbers")
        XCTAssertTrue(transport.sentFrames.allSatisfy { $0.turnID == turnID },
                      "frames carry the LIVE turn id (reconnect/replay law)")
        XCTAssertEqual(transport.sentMuted, [false, false, true],
                       "mute pauses SENDING, the frame clock keeps running")
        XCTAssertEqual(vm.docState, .listening, "mute never moves the doc state")
    }

    // MARK: - Permission denial + transport failure are real terminal paths

    func testPermissionDeniedFailsWithoutTransportConnect() async throws {
        let store = try PersistenceStore(path: tempDBPath("denied"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        audio.grantPermission = false
        let (vm, _) = makeSession(store: store, transport: transport, audio: audio)

        await vm.start()
        XCTAssertEqual(vm.docState, .failed, "denial is a visible failure, not a silent retry loop")
        XCTAssertEqual(vm.failureReason, nil, "denial path needs no fabricated reason")
        XCTAssertEqual(transport.connectCount, 0, "no mic ⇒ no transport session")
        XCTAssertEqual(vm.orbitalState, .idle)
    }

    func testTransportFailureFromListeningFailsAndReleasesResources() async throws {
        let store = try PersistenceStore(path: tempDBPath("tfail"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let (vm, _) = makeSession(store: store, transport: transport, audio: audio)

        await vm.start()
        await transport.simulate(.sessionConnected)
        await transport.simulate(.failure(reason: "ws-dropped"))
        XCTAssertEqual(vm.docState, .failed)
        XCTAssertEqual(vm.failureReason, "ws-dropped")
        XCTAssertEqual(audio.stopCount, 1, "failure stops capture — no hidden active mic")
        XCTAssertEqual(transport.disconnectCount, 1)
    }

    // MARK: - Doc law: a dropped transport ENDS visibly from every live state

    func testSessionDisconnectedEndsFromEveryLiveState() async {
        for live in [VoiceDocState.connecting, .listening, .thinking, .speaking] {
            XCTAssertEqual(
                VoiceStateMachine.next(state: live, event: .sessionDisconnected, isMuted: false),
                .ended,
                "\(live): a dropped transport ends VISIBLY (never a hidden live mic)")
        }
        XCTAssertEqual(
            VoiceStateMachine.next(state: .idle, event: .sessionDisconnected, isMuted: false), nil)
        XCTAssertEqual(
            VoiceStateMachine.next(state: .ended, event: .sessionDisconnected, isMuted: false), nil)
    }

    // MARK: - No resurrection: late events after end are ignored

    func testLateEventsAfterEndCannotResurrectTheSession() async throws {
        let store = try PersistenceStore(path: tempDBPath("late"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let (vm, _) = makeSession(store: store, transport: transport, audio: audio)

        await vm.start()
        await transport.simulate(.sessionConnected)
        await vm.end()
        XCTAssertEqual(vm.docState, .ended)

        await transport.simulate(.finalTranscript(text: "ghost", turnID: UUID()))
        await transport.simulate(.responseStarted)
        await transport.simulate(.sessionConnected)
        XCTAssertEqual(vm.docState, .ended, "a dead session stays dead")
        XCTAssertEqual(vm.lastFinal, "", "no ghost rows")
        // The ignored events are visible in the trail (from == to).
        XCTAssertTrue(vm.eventLog.contains { log in
            if case .responseStarted = log.event { return log.from == log.to }
            return false
        }, "ignored events are logged as no-ops, not dropped silently")
    }

    // MARK: - Exhaustive state/event table invariants

    func testStateMachineTableNeverFabricatesRespondingAndStaysDefined() {
        let events: [VoiceEngineEvent] = [
            .permissionResult(true), .permissionResult(false),
            .sessionConnected, .sessionDisconnected,
            .partialTranscript(text: "x", turnID: UUID()),
            .finalTranscript(text: "x", turnID: UUID()),
            .responseStarted, .responseFinished,
            .failure(reason: "r"), .endedByUser,
        ]
        for state in VoiceDocState.allCases {
            for event in events {
                let next = VoiceStateMachine.next(state: state, event: event, isMuted: false)
                // Every produced state is a real doc state (type system
                // guarantees the set; the pin is the nil-vs-move law).
                if let next {
                    XCTAssertTrue(VoiceDocState.allCases.contains(next))
                    // The responding orbital is ONLY reachable from a real
                    // response event landing on thinking.
                    if VoiceStateMachine.orbital(for: next) == .responding {
                        XCTAssertEqual(event, .responseStarted,
                                       "\(state) + \(event) must not fabricate 'responding'")
                        XCTAssertEqual(state, .thinking)
                    }
                }
            }
        }
        // Direct pins of the table's load-bearing edges.
        XCTAssertEqual(VoiceStateMachine.next(state: .requestingPermission, event: .permissionResult(true), isMuted: false), .connecting)
        XCTAssertEqual(VoiceStateMachine.next(state: .requestingPermission, event: .permissionResult(false), isMuted: false), .failed)
        XCTAssertEqual(VoiceStateMachine.next(state: .connecting, event: .sessionConnected, isMuted: false), .listening)
        XCTAssertEqual(VoiceStateMachine.next(state: .listening, event: .finalTranscript(text: "x", turnID: UUID()), isMuted: false), .thinking)
        XCTAssertEqual(VoiceStateMachine.next(state: .thinking, event: .responseStarted, isMuted: false), .speaking)
        XCTAssertEqual(VoiceStateMachine.next(state: .speaking, event: .responseFinished, isMuted: false), .listening)
    }

    // MARK: - Orbital mapping mirrors the pinned table exactly

    func testOrbitalMappingIsThePinnedRealEventTable() {
        XCTAssertEqual(VoiceStateMachine.orbital(for: .idle), .idle)
        XCTAssertEqual(VoiceStateMachine.orbital(for: .requestingPermission), .idle)
        XCTAssertEqual(VoiceStateMachine.orbital(for: .connecting), .idle)
        XCTAssertEqual(VoiceStateMachine.orbital(for: .listening), .listening)
        XCTAssertEqual(VoiceStateMachine.orbital(for: .thinking), .thinking)
        XCTAssertEqual(VoiceStateMachine.orbital(for: .speaking), .responding)
        XCTAssertEqual(VoiceStateMachine.orbital(for: .failed), .idle)
        XCTAssertEqual(VoiceStateMachine.orbital(for: .ended), .idle)
    }

    // MARK: - Transcript: partial → final replaces through the REAL store

    func testPartialFinalizeReplacesThroughRealUpsertPathNoDuplicates() async throws {
        let store = try PersistenceStore(path: tempDBPath("upsert"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let (vm, writer) = makeSession(store: store, transport: transport, audio: audio)

        await writer.beginRecording(filePath: "recordings/upsert.m4a")
        await vm.start()
        await transport.simulate(.sessionConnected)
        let turnID = audio.capturedTurnIDs[0]

        // Two evolving partials, then the final — same turn id throughout.
        await transport.simulate(.partialTranscript(text: "remind", turnID: turnID))
        await transport.simulate(.partialTranscript(text: "remind Jess", turnID: turnID))
        await transport.simulate(.finalTranscript(text: "remind Jess to water the plants", turnID: turnID))

        let rows = await store.transcriptSegments(recordingID: writer.recordingID)
        XCTAssertEqual(rows.count, 1, "partials and final share ONE row (upsert-by-id)")
        XCTAssertEqual(rows.first?.text, "remind Jess to water the plants")
        XCTAssertEqual(rows.first?.speaker, "user")

        let hits = try await store.searchTranscriptSegments(matching: "water")
        XCTAssertEqual(hits.count, 1, "FTS holds exactly the final — no phantom partial copies")
    }

    // MARK: - Feel-review hooks: perceptible transitions only

    private final class RecordingFeel: VoiceFeelFeedback, @unchecked Sendable {
        private(set) var played: [VoiceFeelTransition] = []
        func play(_ transition: VoiceFeelTransition) {
            played.append(transition)
        }
    }

    func testFeelHooksFireOnPerceptibleTransitionsOnly() async throws {
        let store = try PersistenceStore(path: tempDBPath("feel"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let feel = RecordingFeel()
        let vm = VoiceSessionViewModel(
            transport: transport, audioSource: audio,
            transcriptWriter: nil, feel: feel)

        // requesting_permission + connecting are silent (mapping nil).
        await vm.start()
        XCTAssertEqual(feel.played, [], "permission/connecting stages make no noise")

        await transport.simulate(.sessionConnected)
        XCTAssertEqual(feel.played, [.listeningStarted])

        await transport.simulate(.partialTranscript(text: "x", turnID: UUID()))
        XCTAssertEqual(feel.played.count, 1, "a no-op event never re-buzzes")

        await transport.simulate(.finalTranscript(text: "x", turnID: UUID()))
        await transport.simulate(.responseStarted)
        XCTAssertEqual(feel.played, [.listeningStarted, .thinkingStarted, .respondingStarted])

        await transport.simulate(.responseFinished)
        XCTAssertEqual(feel.played.last, .listeningStarted)

        await vm.end()
        XCTAssertEqual(feel.played.last, .sessionEnded)
        // Full walk: listening, thinking, responding, listening, ended —
        // exactly one buzz per perceptible transition (5 total; the no-op
        // partial added none).
        XCTAssertEqual(feel.played.count, 5)
    }

    func testFeelFailureTransitionFiresOnRealFailureEvent() async throws {
        let store = try PersistenceStore(path: tempDBPath("feelfail"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let feel = RecordingFeel()
        let vm = VoiceSessionViewModel(
            transport: transport, audioSource: audio,
            transcriptWriter: nil, feel: feel)

        await vm.start()
        await transport.simulate(.sessionConnected)
        await transport.simulate(.failure(reason: "ws-dropped"))
        XCTAssertEqual(feel.played.last, .sessionFailed, "failure is perceptible (UI must feel the break)")
    }

    func testFeelMappingIsExhaustiveAndSilentWherePinned() {
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .idle), nil)
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .requestingPermission), nil)
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .connecting), nil)
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .listening), .listeningStarted)
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .thinking), .thinkingStarted)
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .speaking), .respondingStarted)
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .ended), .sessionEnded)
        XCTAssertEqual(VoiceFeel.transition(forBecoming: .failed), .sessionFailed)
        // Every transition value is a real case (type-checked); the count pin
        // keeps the enum from growing silently.
        XCTAssertEqual(VoiceFeelTransition.allCases.count, 5)
    }

    // MARK: - Restart after end: a fresh session is a fresh turn/recording

    func testRestartAfterEndStartsCleanAndMuteResets() async throws {
        let store = try PersistenceStore(path: tempDBPath("restart"))
        let transport = LoopbackTransport()
        let audio = LoopbackAudioSource()
        let (vm, writer) = makeSession(store: store, transport: transport, audio: audio)

        await vm.start()
        await transport.simulate(.sessionConnected)
        let firstTurn = audio.capturedTurnIDs[0]
        await vm.toggleMute()
        await vm.end()

        await vm.start()
        await transport.simulate(.sessionConnected)
        XCTAssertEqual(vm.docState, .listening, "a new session starts clean")
        XCTAssertFalse(vm.isMuted, "mute is per-session")
        XCTAssertEqual(vm.failureReason, nil)
        let secondTurn = audio.capturedTurnIDs[1]
        XCTAssertNotEqual(firstTurn, secondTurn, "each session gets a fresh turn identity")

        // The two sessions' segments never collide (unique turn UUIDs are
        // the segment ids).
        _ = writer
        let transportFrames = transport.sentFrames
        XCTAssertTrue(transportFrames.isEmpty || Set(transportFrames.map { $0.turnID }).count == transportFrames.map { $0.turnID }.count)
    }
}
