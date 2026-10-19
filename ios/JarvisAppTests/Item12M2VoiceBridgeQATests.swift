import XCTest

import DesignSystem
import Persistence
import FeaturesVoice
@testable import JarvisApp

/// Item 12 (Voice M2) — app-target QA over the REAL call⇄voice seam:
/// the call-state→voice-surface mapper, transcript persistence through the
/// REAL store upsert path, and the binder pipeline driven by the REAL
/// CallManager publishers.
@MainActor
final class Item12M2VoiceBridgeQATests: XCTestCase {

    // MARK: - Mapper: every real CallManager callState surface value

    func testMapperCoversEveryCallStateSurfaceValue() {
        XCTAssertEqual(M2CallStateMapper.docState(callState: "idle"), .idle)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "dialing"), .connecting)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "ringing"), .connecting)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "connecting"), .connecting)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "active"), .listening)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "active · speaking"), .speaking)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "active · working"), .thinking)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "active · tool:gateway"), .thinking)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "failed: gateway boom"), .failed)
        XCTAssertEqual(M2CallStateMapper.docState(callState: "something-unknown"), .idle,
                       "unknown surface never fabricates a live voice state")
    }

    /// The orbital is derived from ONE table (doc state) — never a second,
    /// divergent callState→orbital table.
    func testOrbitalDerivesFromTheSingleDocStateTable() {
        let surfaces = ["idle", "dialing", "ringing", "connecting", "active",
                        "active · speaking", "active · working", "failed: x", "junk"]
        for surface in surfaces {
            XCTAssertEqual(
                M2CallStateMapper.orbitalState(callState: surface),
                M2CallStateMapper.orbital(fromDoc: M2CallStateMapper.docState(callState: surface)),
                "orbitalState(callState:) must equal orbital(fromDoc: docState) for \(surface)")
        }
        XCTAssertEqual(M2CallStateMapper.orbital(fromDoc: .listening), .listening)
        XCTAssertEqual(M2CallStateMapper.orbital(fromDoc: .thinking), .thinking)
        XCTAssertEqual(M2CallStateMapper.orbital(fromDoc: .speaking), .responding)
        XCTAssertEqual(M2CallStateMapper.orbital(fromDoc: .ended), .idle)
        // The ONLY path to the responding orbital is the speaking state.
        XCTAssertEqual(M2CallStateMapper.orbitalState(callState: "active · speaking"), .responding)
    }

    // MARK: - Transcript coordinator through the REAL store upsert path

    private func tempStore(_ name: String) throws -> PersistenceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m2-qa-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PersistenceStore(path: dir.appendingPathComponent("store.sqlite").path)
    }

    func testCoordinatorUpsertsSingleAssistantRowThroughRealStore() async throws {
        let store = try tempStore("coord")
        let convo = UUID()
        let coordinator = M2TranscriptCoordinator()

        XCTAssertTrue(coordinator.beginCall(conversationID: convo), "first begin opens the scope")
        await coordinator.recordAssistantTranscript("First utterance.", store: store)

        var rows = try await store.messages(conversationID: convo)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.role, .assistant)
        XCTAssertEqual(rows.first?.content, "First utterance.")

        // Gateway finals are full utterances: the SAME row updates (no
        // duplicate) — the upsert path's contract, exercised live.
        await coordinator.recordAssistantTranscript("First utterance, corrected.", store: store)
        rows = try await store.messages(conversationID: convo)
        XCTAssertEqual(rows.count, 1, "re-recording must never duplicate the row")
        XCTAssertEqual(rows.first?.content, "First utterance, corrected.")

        // End + next call = a FRESH row (per-call transcript identity).
        coordinator.endCall()
        XCTAssertTrue(coordinator.beginCall(conversationID: convo))
        await coordinator.recordAssistantTranscript("Second call.", store: store)
        rows = try await store.messages(conversationID: convo)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.content, "Second call.")
        XCTAssertNotEqual(rows.first?.id, rows.last?.id)
    }

    func testCoordinatorBeginIsIdempotentWithinACall() async throws {
        let store = try tempStore("idem")
        let convo = UUID()
        let coordinator = M2TranscriptCoordinator()
        XCTAssertTrue(coordinator.beginCall(conversationID: convo))
        XCTAssertFalse(coordinator.beginCall(conversationID: convo),
                       "a second begin mid-call must not fork the row identity")
        await coordinator.recordAssistantTranscript("once", store: store)
        let rows = try await store.messages(conversationID: convo)
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Binder: REAL CallManager publishers drive store rows

    func testBinderPipelineWritesRowsFromRealCallManagerEvents() async throws {
        let store = try tempStore("binder")
        let convo = UUID()
        let binder = M2CallTranscriptBinder.shared
        binder.visibleConversationID = convo
        binder.store = store
        defer {
            binder.visibleConversationID = nil
            binder.store = nil
        }

        // Real pipeline: call becomes active → scope opens.
        CallManager.shared.activeCallUUID = UUID()
        CallManager.shared.lastTranscript = nil

        CallManager.shared.lastTranscript = "Hello from the gateway."
        let rowID = try await waitUntilRow(store: store, conversationID: convo, minCount: 1)

        // A second final UPDATES the same row (no duplicate).
        CallManager.shared.lastTranscript = "Hello from the gateway, continued."
        _ = try await waitUntilRow(store: store, conversationID: convo,
                                   minCount: 1, expectLastContent: "Hello from the gateway, continued.")

        // Call ends → scope closes; a stray late transcript writes nothing.
        CallManager.shared.activeCallUUID = nil
        _ = binder.coordinator // keep alive
        try await Task.sleep(nanoseconds: 100_000_000)
        CallManager.shared.lastTranscript = "late ghost"
        try await Task.sleep(nanoseconds: 100_000_000)
        let rows = try await store.messages(conversationID: convo)
        XCTAssertEqual(rows.count, 1, "late events after end cannot resurrect the scope")
        XCTAssertNotEqual(rows.first?.content, "late ghost")
        XCTAssertEqual(rowID, rows.first?.id)
    }

    @discardableResult
    private func waitUntilRow(store: PersistenceStore, conversationID: UUID,
                              minCount: Int, expectLastContent: String? = nil) async throws -> UUID? {
        let deadline = Date().addingTimeInterval(3)
        var rows: [StoredMessage] = []
        while Date() < deadline {
            rows = try await store.messages(conversationID: conversationID)
            if rows.count >= minCount {
                if let expectLastContent {
                    if rows.last?.content == expectLastContent { return rows.first?.id }
                } else {
                    return rows.first?.id
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("expected ≥\(minCount) row(s), got \(rows.count): \(rows.map(\.content))")
        return nil
    }
}
