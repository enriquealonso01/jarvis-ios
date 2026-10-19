import Foundation
import Combine
import DesignSystem
import FeaturesVoice
import Persistence

// MARK: - Item 12 (Voice M2) — app-target call⇄voice bridge
//
// The waveform (UI Law §7) starts a REAL CallKit call (CallManager
// placeDirectCall → CXProvider → WebRTC). This file is the M2 bridge that
// (a) maps the call's REAL gateway/call states onto the voice layer's doc
// states + kit orbital states (the same table the package tests pin), and
// (b) persists assistant transcripts from the live call into the chat
// transcript through the real store's upsert path — "transcript persists
// as normal chat messages either way" (§7).

/// Pure M2 mapping: a call's real state (CallManager.callState) + the
/// gateway's live stage, onto the voice layer surface. CallManager strings
/// are legacy v1 surface values; the adapter treats them as the real
/// provider-event vocabulary.
public enum M2CallStateMapper {
    /// callState → doc state.
    public static func docState(callState: String) -> VoiceDocState {
        switch callState {
        case "idle": return .idle
        case "dialing": return .connecting
        case "ringing": return .connecting
        case "connecting": return .connecting
        case "active": return .listening
        default:
            if callState.hasPrefix("active · speaking") { return .speaking }
            if callState.hasPrefix("active ·") { return .thinking }
            if callState.hasPrefix("failed") { return .failed }
            return .idle
        }
    }

    /// callState → kit orbital state (idle/listening/thinking/responding,
    /// the ONLY four the kit renders). Derived from the doc state — one
    /// source of truth, no divergent tables.
    public static func orbitalState(callState: String) -> OrbitalState {
        orbital(fromDoc: docState(callState: callState))
    }

    /// Doc state → orbital, the pinned package table (VoiceSession.swift).
    public static func orbital(fromDoc doc: VoiceDocState) -> OrbitalState {
        switch doc {
        case .idle, .requestingPermission, .connecting: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .responding
        case .ended, .failed: return .idle
        }
    }
}

/// App-target feel adapter: VoiceFeelFeedback → the app's centralized
/// Haptics (backlog #9 — every surface fires the same patterns, respects
/// the settings toggle). UIFeedbackGenerator is main-thread-only, so the
/// hop to the main actor is explicit (Swift 6: a non-isolated protocol
/// requirement cannot cross into main-actor-isolated code silently).
public final class M2VoiceHapticsAdapter: VoiceFeelFeedback {
    public init() {}
    public nonisolated func play(_ transition: VoiceFeelTransition) {
        MainActor.assumeIsolated {
            switch transition {
            case .listeningStarted: Haptics.tap()
            case .thinkingStarted: Haptics.tap()
            case .respondingStarted: Haptics.tap()
            case .sessionEnded: Haptics.success()
            case .sessionFailed: Haptics.error()
            }
        }
    }
}

/// Bridges a live call's assistant transcript into the chat store: one
/// upserted `StoredMessage` (role .assistant, status .sent) per final
/// utterance — deduped by id so Combine re-emissions never duplicate rows.
/// §7: "Transcript persists as normal chat messages either way."
@MainActor
public final class M2TranscriptCoordinator: ObservableObject {
    /// id for the current call's assistant message (one row per call —
    /// gateway `transcript` messages are full-utterance finals).
    private var callMessageID: UUID?
    private var callConversationID: UUID?

    public init() {}

    /// Begin a call-scoped transcript capture for `conversationID`.
    /// Returns false when a call is already being captured (idempotent).
    @discardableResult
    public func beginCall(conversationID: UUID) -> Bool {
        guard callMessageID == nil else { return false }
        callConversationID = conversationID
        callMessageID = UUID()
        return true
    }

    /// The real gateway transcript event → upsert through the REAL store
    /// path. Creates/updates the single assistant row for the call.
    public func recordAssistantTranscript(_ text: String,
                                          store: PersistenceStore) async {
        guard let id = callMessageID, let conversationID = callConversationID else { return }
        await store.upsert(StoredMessage(
            id: id,
            conversationID: conversationID,
            role: .assistant,
            content: text,
            status: .sent,
            pendingSync: false))
    }

    /// Call over: release the capture scope (next call gets a fresh row).
    public func endCall() {
        callMessageID = nil
        callConversationID = nil
    }
}

// MARK: - Call⇄chat binder (app singleton)

/// Observes the REAL CallManager and drives the transcript coordinator:
/// call start opens a capture scope on the visible conversation, gateway
/// finals upsert rows, call end closes the scope. Store + conversation are
/// supplied by the chat host on appear (the shell owns one shared store).
@MainActor
public final class M2CallTranscriptBinder: ObservableObject {
    public static let shared = M2CallTranscriptBinder()
    public let coordinator = M2TranscriptCoordinator()
    /// The conversation currently on screen (chat host sets it).
    public var visibleConversationID: UUID?
    /// The shell's shared store (chat host sets it).
    public var store: PersistenceStore?
    private var cancellables: [Combine.AnyCancellable] = []

    private init() {
        CallManager.shared.$activeCallUUID
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uuid in
                Task { @MainActor in self?.handleCallActive(uuid) }
            }
            .store(in: &cancellables)
        CallManager.shared.$lastTranscript
            .dropFirst()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                Task { @MainActor in await self?.record(text) }
            }
            .store(in: &cancellables)
    }

    private func handleCallActive(_ uuid: UUID?) {
        if uuid != nil {
            // Rows land in the conversation the user called from (chat
            // context). Calls started outside chat persist via the call log
            // only — deviation pinned here, not fabricated per-conversation.
            guard let convo = visibleConversationID else { return }
            coordinator.beginCall(conversationID: convo)
        } else {
            coordinator.endCall()
        }
    }

    private func record(_ text: String) async {
        let target = store ?? PersistenceStore()
        await coordinator.recordAssistantTranscript(text, store: target)
    }
}
