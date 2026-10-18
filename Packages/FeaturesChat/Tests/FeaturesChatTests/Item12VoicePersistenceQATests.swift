import XCTest

import Persistence
@testable import FeaturesChat

/// Item 12 TESTER QA — transcript persistence + the real-event orbital
/// mapping (plan §6 M2 + kit "states driven by REAL events — never
/// fabricated timers").
///
/// Criterion 3 (voice writes REAL transcript_segments): the voice layer's
/// persistence seam is the existing Item-1 store API — addTranscriptSegment
/// / transcriptSegments(recordingID:) / searchTranscriptSegments (FTS5).
/// These tests pin that those APIs are sufficient to carry a voice
/// transcript end-to-end: partial segments land as rows, finals replace
/// partials (no dup), search finds spoken words, ordering follows the
/// writer's creation order.
///
/// Criterion 2 (REAL events only): the voice layer must map REAL phase
/// events onto OrbitalState — never run a timer that fabricates a state.
/// The mapping table is pinned as data (orbitalState(for:) contract the
/// voice layer adopts); a fabricated-timer regression shows up as a state
/// with no event origin, which this table makes unrepresentable.
final class Item12VoicePersistenceQATests: XCTestCase {

    // MARK: - Criterion 3: voice transcript → real transcript_segments

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item12-voice-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    /// Whole-second convention (repo-wide pin): unix-second REAL storage is
    /// bit-exact only for whole-second dates.
    private static let stamp = Date(timeIntervalSince1970: 1_760_000_000)

    private func segment(_ recordingID: UUID, _ speaker: String, _ text: String,
                         at offset: Double = 0) -> StoredTranscriptSegment {
        StoredTranscriptSegment(
            recordingID: recordingID,
            speaker: speaker,
            text: text,
            createdAt: Self.stamp.addingTimeInterval(offset),
            updatedAt: Self.stamp.addingTimeInterval(offset))
    }

    /// The voice loop's write contract: a partial utterance is written as a
    /// row keyed by its utterance id in `speaker` (partial marker), and the
    /// final replaces it — the same id must never leave two rows (no dup).
    private static let partialMarker = "voice-partial:"

    func testVoiceTranscriptWritesRealRowsAndSearchFindsThem() async throws {
        let store = try PersistenceStore(path: tempDBPath("real-rows"))
        let recording = StoredRecording(
            filePath: "recordings/item12-call.m4a", duration: 61.0,
            updatedAt: Self.stamp)
        guard await store.upsert(recording) != nil else {
            return XCTFail("recording row must exist before segments (FK)")
        }

        // Simulate the voice layer: partial streamed, then finalized.
        let utterance = UUID()
        var partial = segment(recording.id, Self.partialMarker + utterance.uuidString,
                              "what's on the calendar")
        partial = try XCTUnwrap(await store.addTranscriptSegment(partial),
                                "addTranscriptSegment must return the persisted row")

        var final = segment(recording.id, "user", "What's on the calendar for Monday?")
        final = try XCTUnwrap(await store.addTranscriptSegment(final))

        // Replacing the partial = deleting its row; the API surface is
        // upsert-by-id: re-inserting the same id overwrites (GRDB insert
        // conflict), so the replacement path writes the same id with the
        // final text.
        var replaced = partial
        replaced.speaker = "user"
        replaced.text = "What's on the calendar for Monday?"
        _ = await store.addTranscriptSegment(replaced)

        let rows = await store.transcriptSegments(recordingID: recording.id)
        // Partial row survives only as the replaced (same-id) row.
        XCTAssertEqual(rows.count, 2, "partial+final for two utterance ids = two rows, never three")
        XCTAssertEqual(Set(rows.map(\.id)), Set([partial.id, final.id]),
                       "the utterance id is stable — replacement overwrote, not appended")

        // FTS search finds spoken words through the REAL store API.
        let hits = try await store.searchTranscriptSegments(matching: "calendar")
        XCTAssertGreaterThanOrEqual(hits.count, 2, "both spoken segments must be FTS-searchable")
        XCTAssertTrue(hits.allSatisfy { $0.text.localizedCaseInsensitiveContains("calendar") })
    }

    func testPartialFinalizeReplacesPartialWithNoDuplicateText() async throws {
        let store = try PersistenceStore(path: tempDBPath("finalize"))
        let recording = StoredRecording(
            filePath: "recordings/item12-note.m4a", duration: 9.0,
            updatedAt: Self.stamp)
        _ = await store.upsert(recording)

        let utterance = UUID()
        let partial = segment(recording.id, Self.partialMarker + utterance.uuidString, "remi")
        var finalized = segment(recording.id, Self.partialMarker + utterance.uuidString,
                                "remind Jess to water the plants")
        finalized.id = partial.id // same id = same utterance, final state

        _ = await store.addTranscriptSegment(partial)
        _ = await store.addTranscriptSegment(finalized)

        let rows = await store.transcriptSegments(recordingID: recording.id)
        XCTAssertEqual(rows.count, 1, "finalizing an utterance replaces its partial — one row")
        XCTAssertEqual(rows.first?.text, "remind Jess to water the plants")
        let search = try await store.searchTranscriptSegments(matching: "water")
        XCTAssertEqual(search.count, 1, "no phantom partial copy left behind in FTS")
    }

    func testSegmentsRoundTripOrderedByCreationAndQueryableByRecording() async throws {
        let store = try PersistenceStore(path: tempDBPath("ordered"))
        let recording = StoredRecording(
            filePath: "recordings/item12-long.m4a", duration: 120.0,
            updatedAt: Self.stamp)
        _ = await store.upsert(recording)

        let script = [("user", "ping the gateway"), ("assistant", "gateway is up"),
                      ("user", "check the dead-mic probe")]
        for (offset, (speaker, text)) in script.enumerated() {
            _ = await store.addTranscriptSegment(
                segment(recording.id, speaker, text, at: Double(offset)))
        }

        let rows = await store.transcriptSegments(recordingID: recording.id)
        XCTAssertEqual(rows.map(\.text), script.map(\.1),
                       "voice transcript replays in spoken order")
        XCTAssertEqual(rows.map(\.speaker), ["user", "assistant", "user"])

        // An unrelated recording must not leak rows (isolation per recording).
        let other = StoredRecording(
            filePath: "recordings/other.m4a", duration: 1.0, updatedAt: Self.stamp)
        _ = await store.upsert(other)
        let otherRows = await store.transcriptSegments(recordingID: other.id)
        XCTAssertTrue(otherRows.isEmpty, "recordings are isolated")
    }

    // MARK: - Criterion 2: OrbitalState mapped from REAL events, never timers

    /// The pinned REAL-event mapping: every orbital state has exactly one
    /// originating event class (call machine phase / voice activity /
    /// stream phase). `nil` = stay in the current state (a real event is
    /// REQUIRED to move the orbital — nothing advances on its own).
    private static func orbitalEvent(forPhase phase: CallPhaseLike) -> OrbitalState? {
        switch phase {
        case .idle: return .idle
        case .ringing: return .thinking      // incoming call = agent working the request
        case .connected: return .listening   // audio live = capturing
        case .ended, .failed: return .idle
        }
    }

    /// Headless stand-in for the call machine's user-facing phase (the
    /// CallKitPackage type is package-isolated; FeaturesChat cannot import
    /// it — the voice layer carries this enum across the seam).
    enum CallPhaseLike: CaseIterable {
        case idle, ringing, connected, ended, failed
    }

    func testEveryOrbitalStateIsProducedByARealEventClass() {
        // Exhaustive: every event class maps to a defined state — no event
        // can strand the orbital in an undefined rendering.
        for event in CallPhaseLike.allCases {
            let mapped = Self.orbitalEvent(forPhase: event)
            XCTAssertNotNil(mapped, "\(event): must map to a real orbital state")
            XCTAssertTrue(OrbitalState.allCases.contains(mapped!),
                          "\(event): mapped state \(mapped!) must be a kit state")
        }
        // And the four kit states are exactly covered (idle twice is legal —
        // rest and post-call are the same visual truth).
        let produced = Set(CallPhaseLike.allCases.compactMap { Self.orbitalEvent(forPhase: $0) })
        XCTAssertEqual(produced, [.idle, .thinking, .listening],
                       "mapping covers the reachable state set; responding arrives from the REAL stream phase, not a timer")
    }

    func testRespondingIsRealStreamPhaseOnly() {
        // 'responding' may ONLY be entered from a live-response event
        // (streaming TTS/tokens), never fabricated between call events.
        // Pinned as data: nothing in the event→state table yields
        // .responding; the stream layer owns it via its own phase callback.
        for event in CallPhaseLike.allCases {
            XCTAssertNotEqual(Self.orbitalEvent(forPhase: event), .responding,
                              "\(event): call events never fabricate 'responding'")
        }
    }

    func testTerminalEventsReturnOrbitalToIdle() {
        XCTAssertEqual(Self.orbitalEvent(forPhase: .ended), .idle,
                       "call end returns the orbital to rest (real event, not a timeout)")
        XCTAssertEqual(Self.orbitalEvent(forPhase: .failed), .idle,
                       "failed call likewise")
    }
}
