import Foundation
import DesignSystem
import Persistence

// MARK: - Item 12 (Voice M2) — in-chat voice layer (UI Law §7)
//
// The in-chat voice layer: mic capture → transport → transcript, with the
// doc §Voice state machine and the OrbitalState mapping driven ONLY by REAL
// engine events (kit spec law — no fabricated timers anywhere in this file).
//
// The REAL seams (the app target conforms; loopback implementations live in
// the QA suite and conform to the SAME protocols):
//   • VoiceTransporting — connect/disconnect/sendAudioFrame/onEvent
//     (doc §"Required transport adapters"; the production impl rides the
//     deployed streaming pipeline — WebRTC where available, WS if reliable).
//   • VoiceAudioSourcing — mic permission + frame delivery (AVAudioEngine
//     tap in the app target; a scripted frame source in tests).
//
// Sequence numbers + turnId ride every partial (doc: reconnect/replay law).

/// Doc §Voice states, in order. `idle → requesting_permission → connecting →
/// listening ⇄ thinking ⇄ speaking`, with `muted`, `failed`, `ended`.
public enum VoiceDocState: String, Sendable, Equatable, CaseIterable {
    case idle
    case requestingPermission
    case connecting
    case listening
    case thinking
    case speaking
    case failed
    case ended
}

/// A normalized mic frame (16 kHz mono PCM is the production contract; the
/// layer is format-agnostic — the audio source declares its format).
public struct VoiceAudioFrame: Sendable, Equatable {
    public let sequence: Int
    public let turnID: UUID
    public let sampleCount: Int

    public init(sequence: Int, turnID: UUID, sampleCount: Int) {
        self.sequence = sequence
        self.turnID = turnID
        self.sampleCount = sampleCount
    }
}

/// REAL engine events — the ONLY inputs that may move the doc state or the
/// orbital. No timers, no synthetic "processing…" beats.
public enum VoiceEngineEvent: Sendable, Equatable {
    /// Permission resolved (granted/denied) — a real OS callback.
    case permissionResult(Bool)
    /// Transport session established.
    case sessionConnected
    /// Transport dropped (doc: suspend/resume or end visibly).
    case sessionDisconnected
    /// Partial user utterance (streaming ASR, replaces the prior partial).
    case partialTranscript(text: String, turnID: UUID)
    /// Final user utterance — the turn is fixed; agent work begins.
    case finalTranscript(text: String, turnID: UUID)
    /// The agent's answer started streaming (tokens or TTS).
    case responseStarted
    /// The answer finished — back to listening.
    case responseFinished
    /// Terminal failure from transport or agent.
    case failure(reason: String)
    /// Clean end (user pill / adapter).
    case endedByUser
}

/// Transport adapter seam (doc §"Required transport adapters"):
/// connect/disconnect/sendAudioFrame/onEvent. The loopback transport in the
/// QA suite and the production WS/WebRTC transport conform to the SAME
/// protocol — the layer cannot tell them apart.
public protocol VoiceTransporting: AnyObject, Sendable {
    var onEvent: (@Sendable (VoiceEngineEvent) async -> Void)? { get set }
    func connect() async
    func disconnect() async
    /// `muted` sources send silence-or-nothing (doc: mute pauses mic
    /// SENDING); the layer keeps the capture clock running either way.
    func sendAudioFrame(_ frame: VoiceAudioFrame, muted: Bool) async
}

/// Mic adapter seam: user-initiated permission (doc: "must be
/// user-initiated") + frame delivery while listening.
public protocol VoiceAudioSourcing: AnyObject, Sendable {
    var onFrame: (@Sendable (VoiceAudioFrame) async -> Void)? { get set }
    /// MUST be called from a user gesture path only.
    func requestPermission() async -> Bool
    func startCapturing(turnID: UUID) async
    func stopCapturing() async
}

// MARK: - Transcript persistence bridge

/// Writes voice turns through the VERIFIED Item-1 upsert path
/// (`addTranscriptSegment` — upsert-by-id, final replaces partial, FTS
/// trigger re-indexes on update). The recording row anchors the FK; one
/// recording per voice session.
public actor VoiceTranscriptWriter {
    public let recordingID: UUID
    private let store: PersistenceStore

    public init(store: PersistenceStore, recordingID: UUID) {
        self.store = store
        self.recordingID = recordingID
    }

    /// Anchor row (recordings FK) — call once when the session starts.
    public func beginRecording(filePath: String, duration: Double = 0) async {
        _ = await store.upsert(StoredRecording(
            id: recordingID, filePath: filePath, duration: duration))
    }

    /// One turn = one segment id: the turn's UUID IS the segment id, so the
    /// partial and its final share identity (upsert-by-id ⇒ final REPLACES
    /// partial) and ids are globally unique across sessions — no collision
    /// can corrupt an earlier session's transcript.
    public func writePartial(text: String, turnID: UUID) async {
        _ = await store.addTranscriptSegment(StoredTranscriptSegment(
            id: turnID, recordingID: recordingID,
            speaker: "user", text: text))
    }

    /// The finalized utterance: same id, final text, speaker fixed.
    public func writeFinal(text: String, turnID: UUID, speaker: String) async {
        _ = await store.addTranscriptSegment(StoredTranscriptSegment(
            id: turnID, recordingID: recordingID,
            speaker: speaker, text: text))
    }

    /// Assistant answers land as their own segments (speaker attribution:
    /// doc "separate speaker attribution").
    public func writeAssistant(text: String, turnID: UUID) async {
        _ = await store.addTranscriptSegment(StoredTranscriptSegment(
            id: turnID, recordingID: recordingID,
            speaker: "assistant", text: text))
    }

    /// Stamp the anchor row's duration when the session ends (fetch →
    /// mutate → upsert so the host's real filePath survives).
    public func finishRecording(duration: Double) async {
        var row = await store.getRecording(id: recordingID)
        row?.duration = duration
        if let row {
            _ = await store.upsert(row)
        }
    }
}

// MARK: - Feel-review hooks (haptics/sounds on state transitions)

/// A perceptible voice-layer transition. The feel layer (UI Law feel-review:
/// the app must FEEL alive at state changes) receives exactly these — never
/// raw events, so ignored/no-op events cannot buzz.
public enum VoiceFeelTransition: String, Sendable, Equatable, CaseIterable {
    /// Mic went live — light tap.
    case listeningStarted
    /// Agent is working — subtle.
    case thinkingStarted
    /// Response started — success-shaped.
    case respondingStarted
    /// Clean end.
    case sessionEnded
    /// Failure.
    case sessionFailed
}

/// The feel seam. The app target implements it with the shared `Haptics`
/// enum + a system sound; QA stubs record. Must be main-actor-friendly and
/// cheap — called on the state-change path.
public protocol VoiceFeelFeedback: AnyObject, Sendable {
    func play(_ transition: VoiceFeelTransition)
}

/// The pinned doc-state → feel mapping (exhaustive; pure).
public enum VoiceFeel {
    public static func transition(forBecoming state: VoiceDocState) -> VoiceFeelTransition? {
        switch state {
        case .listening: return .listeningStarted
        case .thinking: return .thinkingStarted
        case .speaking: return .respondingStarted
        case .ended: return .sessionEnded
        case .failed: return .sessionFailed
        case .idle, .requestingPermission, .connecting: return nil
        }
    }
}

// MARK: - The voice session (state machine + orbital mapping)

/// Maps REAL events to state. Pure, exhaustive, unit-pinned.
public enum VoiceStateMachine {

    /// Doc §Voice transition table. `nil` = event ignored in that state
    /// (e.g. a late partial after end must not resurrect the session).
    public static func next(
        state: VoiceDocState, event: VoiceEngineEvent, isMuted: Bool
    ) -> VoiceDocState? {

        switch event {
        case .permissionResult(let granted):
            switch state {
            case .requestingPermission:
                return granted ? .connecting : .failed
            default:
                return nil
            }

        case .sessionConnected:
            return state == .connecting ? .listening : nil

        case .sessionDisconnected:
            // Doc: suspend/resume or end VISIBLY — never keep a hidden
            // active mic. A dropped transport from any live state ends.
            switch state {
            case .listening, .thinking, .speaking, .connecting:
                return .ended
            default:
                return nil
            }

        case .partialTranscript:
            // A partial proves the mic is live: listening ⇄ (thinking) —
            // user speech during agent work pulls the state back to
            // listening (barge-in) only if the transport reported it as
            // live audio; otherwise ignored while thinking/speaking.
            return state == .listening ? .listening : nil

        case .finalTranscript:
            return state == .listening ? .thinking : nil

        case .responseStarted:
            return state == .thinking ? .speaking : nil

        case .responseFinished:
            return state == .speaking ? .listening : nil

        case .failure:
            switch state {
            case .requestingPermission, .connecting, .listening,
                 .thinking, .speaking:
                return .failed
            default:
                return nil
            }

        case .endedByUser:
            switch state {
            case .requestingPermission, .connecting, .listening,
                 .thinking, .speaking:
                return .ended
            default:
                return nil
            }
        }
    }

    /// The REAL-event orbital mapping (UI Law §7 + kit "states driven by
    /// REAL events"). Mirrors the pinned table in
    /// Item12VoicePersistenceQATests: call events never fabricate
    /// `.responding`; only the live response event yields it.
    public static func orbital(for state: VoiceDocState) -> OrbitalState {
        switch state {
        case .idle, .failed, .ended, .requestingPermission, .connecting:
            return .idle
        case .listening:
            return .listening
        case .thinking:
            return .thinking
        case .speaking:
            return .responding
        }
    }
}

/// The observable session the app-target host renders. Every published
/// property is written ONLY inside `apply(_:)` from REAL engine events (or
/// user intents that produce adapter calls — never direct state writes).
@MainActor
public final class VoiceSessionViewModel: ObservableObject {

    @Published public private(set) var docState: VoiceDocState = .idle
    @Published public private(set) var lastPartial: String = ""
    @Published public private(set) var lastFinal: String = ""
    @Published public private(set) var lastResponse: String = ""
    @Published public private(set) var isMuted = false
    @Published public private(set) var failureReason: String?

    /// Every REAL event application — the QA/telemetry trail proves no
    /// state exists that no event produced. User intents are logged
    /// separately (`intentLog`) so the trail never fabricates an event.
    public private(set) var eventLog: [(event: VoiceEngineEvent, from: VoiceDocState, to: VoiceDocState)] = []
    public private(set) var intentLog: [String] = []

    public let transcriptWriter: VoiceTranscriptWriter?
    /// Feel-review hook: fired exactly when the doc state perceptibly
    /// changes (never on ignored events — the mapping returns nil).
    public private(set) var feel: (any VoiceFeelFeedback)?
    private let transport: any VoiceTransporting
    private let audioSource: any VoiceAudioSourcing
    /// The active turn: one mic-open period; partials mutate it, a final
    /// closes it.
    private var currentTurnID = UUID()
    private var frameSequence = 0
    private var responseTurnID = UUID()

    public init(transport: any VoiceTransporting,
                audioSource: any VoiceAudioSourcing,
                transcriptWriter: VoiceTranscriptWriter? = nil,
                feel: (any VoiceFeelFeedback)? = nil) {
        self.transport = transport
        self.audioSource = audioSource
        self.transcriptWriter = transcriptWriter
        self.feel = feel
        transport.onEvent = { [weak self] event in
            await self?.handle(event)
        }
        audioSource.onFrame = { [weak self] frame in
            await self?.forwardFrame(frame)
        }
    }

    // MARK: User intents (UI Law §7 in-chat layer)

    /// Waveform/waveform-pill start: permission first (user-initiated), then
    /// transport connect. No state leaps — only real callbacks move it.
    public func start() async {
        guard docState == .idle || docState == .ended || docState == .failed else { return }
        intentLog.append("start:\(docState)")
        docState = .requestingPermission
        let granted = await audioSource.requestPermission()
        await handle(.permissionResult(granted))
    }

    public func toggleMute() {
        isMuted.toggle()
    }

    /// End pill / immersive end: stops capture + transport, releases
    /// resources (doc: "end stops tracks and releases server resources").
    public func end() async {
        await audioSource.stopCapturing()
        await transport.disconnect()
        await handle(.endedByUser)
    }

    // MARK: Event handling (the only mutation path)

    private func handle(_ event: VoiceEngineEvent) async {
        guard let next = VoiceStateMachine.next(state: docState, event: event,
                                                isMuted: isMuted) else {
            eventLog.append((event, docState, docState))
            return
        }
        let from = docState
        eventLog.append((event, from, next))

        switch event {
        case .permissionResult(true):
            await transport.connect() // .connecting until sessionConnected
        case .sessionConnected:
            currentTurnID = UUID()
            await audioSource.startCapturing(turnID: currentTurnID)
        case .partialTranscript(let text, _):
            lastPartial = text
            await transcriptWriter?.writePartial(text: text, turnID: currentTurnID)
        case .finalTranscript(let text, _):
            lastPartial = ""
            lastFinal = text
            await transcriptWriter?.writeFinal(text: text, turnID: currentTurnID, speaker: "user")
            currentTurnID = UUID() // next utterance is a new turn
        case .responseStarted:
            responseTurnID = UUID()
        case .responseFinished:
            break
        case .failure(let reason):
            failureReason = reason
            await audioSource.stopCapturing()
            await transport.disconnect()
        case .endedByUser:
            break
        case .sessionDisconnected:
            await audioSource.stopCapturing()
        default:
            break
        }

        docState = next
        if let feelTransition = VoiceFeel.transition(forBecoming: next) {
            feel?.play(feelTransition)
        }
    }

    /// Mic frames ride the transport with sequence numbers + the live turn
    /// id (doc reconnect/replay law). Mute pauses SENDING.
    private func forwardFrame(_ frame: VoiceAudioFrame) async {
        frameSequence += 1
        let framed = VoiceAudioFrame(
            sequence: frameSequence, turnID: currentTurnID,
            sampleCount: frame.sampleCount)
        let muted = isMuted
        await transport.sendAudioFrame(framed, muted: muted)
    }

    /// The assistant answer text, streamed; the host feeds completions and
    /// the layer persists the final through the upsert path.
    public func recordResponse(_ text: String) async {
        lastResponse = text
        await transcriptWriter?.writeAssistant(text: text, turnID: responseTurnID)
    }

    public var orbitalState: OrbitalState {
        VoiceStateMachine.orbital(for: docState)
    }
}
