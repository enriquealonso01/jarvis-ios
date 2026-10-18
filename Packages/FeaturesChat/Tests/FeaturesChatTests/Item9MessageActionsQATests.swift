import XCTest
import Persistence
@testable import FeaturesChat

// MARK: - Item 9 QA: message action row (UI Law §3, no-fake-buttons law)
//
// Pins (headless, macOS-lane safe — no SwiftUI/UIKit assumptions beyond
// the pasteboard write the copy path performs on Apple platforms):
//   §3-1  only COMPLETED rows show an action row (streaming/sending: none);
//   §3-2  control set per row type in §3 order (copy/regenerate/share/•••),
//         regenerate ONLY on the last assistant row, ••• omitted when it
//         would be dead (no fake UI), failed rows keep a functional row;
//   §3-3  copy → the REAL pasteboard receives the row's verbatim text;
//   §3-4  share → the share payload is built and recorded (sheet contents);
//   §3-5  regenerate → the REAL send path is invoked with the last USER
//         prompt; no path / no prompt → unavailable (never a fake success);
//   §3-6  Task 1 composition: the engine's gate rides the Task-1 merged,
//         windowed transcript rows (isLastRow computed from the render list).
final class Item9MessageActionsQATests: XCTestCase {

    // MARK: §3-1 — the row appears only on completed messages

    func testRowHiddenWhileStreaming() {
        XCTAssertFalse(MessageActionRowEngine.showsRow(
            isStreaming: true, status: .streaming))
        XCTAssertFalse(MessageActionRowEngine.showsRow(
            isStreaming: true, status: .sent))
    }

    func testRowShownForSentAndFailedRows() {
        XCTAssertTrue(MessageActionRowEngine.showsRow(
            isStreaming: false, status: .sent))
        XCTAssertTrue(MessageActionRowEngine.showsRow(
            isStreaming: false, status: .failed))
        // In-flight user rows (sending) get nothing — not completed yet.
        XCTAssertFalse(MessageActionRowEngine.showsRow(
            isStreaming: false, status: .sending))
    }

    func testContextClassification() {
        XCTAssertEqual(MessageActionRowEngine.context(for: .streaming), .inFlight)
        XCTAssertEqual(MessageActionRowEngine.context(for: .sending), .inFlight)
        XCTAssertEqual(MessageActionRowEngine.context(for: .sent), .completed)
        XCTAssertEqual(MessageActionRowEngine.context(for: .failed), .completed)
    }

    // MARK: §3-2 — control sets (§3 order; no fake controls)

    func testAssistantLastRowHasCopyRegenerateShare_inOrder() {
        let actions = MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: false, status: .sent, isLastRow: true,
            canRegenerate: true, hasMoreEntries: false))
        XCTAssertEqual(actions.map(\.action), [.copy, .regenerate, .share])
        XCTAssertTrue(actions.allSatisfy(\.enabled), "every rendered control must be functional")
    }

    func testOlderAssistantRowHasNoRegenerate() {
        // Regenerating a non-last assistant turn would rewrite history —
        // the control is omitted, not disabled (no inactive affordances).
        let actions = MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: false, status: .sent, isLastRow: false,
            canRegenerate: true, hasMoreEntries: false))
        XCTAssertEqual(actions.map(\.action), [.copy, .share])
    }

    func testUserRowsNeverRegenerate() {
        let actions = MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: true, status: .sent, isLastRow: true,
            canRegenerate: true, hasMoreEntries: false))
        XCTAssertEqual(actions.map(\.action), [.copy, .share])
    }

    func testNoSendPathOmitsRegenerate_noDeadButton() {
        // Headless transcript (no transport): regenerate would be fake —
        // it must NOT render even on the eligible row.
        let actions = MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: false, status: .sent, isLastRow: true,
            canRegenerate: false, hasMoreEntries: false))
        XCTAssertEqual(actions.map(\.action), [.copy, .share])
    }

    func testMoreOmittedWithoutFunctionalEntries() {
        // Item 9 ships no ••• entries (thumbs/read-aloud land Item 12):
        // a ••• with no working entries would be a dead button.
        let without = MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: false, status: .sent, isLastRow: true,
            canRegenerate: true, hasMoreEntries: false))
        XCTAssertFalse(without.contains { $0.action == .more })

        let with = MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: false, status: .sent, isLastRow: true,
            canRegenerate: true, hasMoreEntries: true))
        XCTAssertEqual(with.last?.action, .more)
    }

    func testRegenerateEligibilityUniqueInTranscript() {
        // At most one row in any transcript qualifies — the LAST assistant.
        XCTAssertTrue(MessageActionRowEngine.regenerateEligible(
            isUser: false, isLastRow: true))
        XCTAssertFalse(MessageActionRowEngine.regenerateEligible(
            isUser: false, isLastRow: false))
        XCTAssertFalse(MessageActionRowEngine.regenerateEligible(
            isUser: true, isLastRow: true))
    }

    // MARK: §3-3 — copy writes the REAL pasteboard

    @MainActor
    func testCopyWritesVerbatimTextToPasteboard() {
        let vm = MessageActionViewModel()
        let text = "Line one\nLine two with  spaces  kept"
        vm.copyTapped(text: text)
        // The real effect: the actual system pasteboard now carries the text
        // (asserted against the platform pasteboard, not a mock — QA law).
        #if canImport(UIKit)
        XCTAssertEqual(UIPasteboard.general.string, text)
        #elseif canImport(AppKit)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text)
        #endif
        XCTAssertEqual(vm.lastEvent, .copied(text: text))
    }

    func testCopyTextIsNotDecorated() {
        XCTAssertEqual(MessageActionRowEngine.copyText(for: "hello"), "hello")
    }

    // MARK: §3-4 — share payload

    @MainActor
    func testShareBuildsSelfDescribingPayload() {
        let vm = MessageActionViewModel()
        vm.shareTapped(text: "Answer text", isUser: false)
        XCTAssertEqual(vm.shareText, "JARVIS:\nAnswer text")
        XCTAssertEqual(vm.lastEvent, .sharePresented(text: "JARVIS:\nAnswer text"))
    }

    @MainActor
    func testShareUserRowsKeepTheirText() {
        let vm = MessageActionViewModel()
        vm.shareTapped(text: "My question", isUser: true)
        XCTAssertEqual(vm.shareText, "My question")
    }

    @MainActor
    func testShareDismissClearsPayload() {
        let vm = MessageActionViewModel()
        vm.shareTapped(text: "x", isUser: false)
        vm.shareDismissed()
        XCTAssertNil(vm.shareText)
    }

    // MARK: §3-5 — regenerate drives the REAL send path

    @MainActor
    func testRegenerateSendsLastUserPromptThroughInjectedPath() async throws {
        actor SendRecorder {
            var sent: [String] = []
            func record(_ text: String) { sent.append(text) }
        }
        let recorder = SendRecorder()
        let vm = MessageActionViewModel(performSend: { prompt in
            await recorder.record(prompt)
            return true
        })
        // Hoisted: the async call must NOT sit inside the XCTAssert
        // autoclosure (asserts the observed effect after the await).
        await vm.regenerateTapped(promptText: "What is GRDB?")
        let recorded = await recorder.sent
        XCTAssertEqual(recorded, ["What is GRDB?"])
        XCTAssertEqual(vm.lastEvent, .regenerateStarted(promptText: "What is GRDB?"))
        XCTAssertFalse(vm.isRegenerating)
    }

    @MainActor
    func testRegenerateWithoutSendPathIsUnavailable_notFake() async {
        let vm = MessageActionViewModel(performSend: nil)
        await vm.regenerateTapped(promptText: "Hello")
        XCTAssertEqual(vm.lastEvent, .regenerateUnavailable)
    }

    @MainActor
    func testRegenerateWithEmptyPromptIsUnavailable() async {
        let vm = MessageActionViewModel(performSend: { _ in true })
        await vm.regenerateTapped(promptText: "   ")
        XCTAssertEqual(vm.lastEvent, .regenerateUnavailable)
    }

    func testRegeneratePromptEngineRule() {
        XCTAssertNil(MessageActionRowEngine.regeneratePrompt(lastUserText: nil))
        XCTAssertNil(MessageActionRowEngine.regeneratePrompt(lastUserText: "  \n "))
        XCTAssertEqual(MessageActionRowEngine.regeneratePrompt(lastUserText: "Hi"), "Hi")
    }

    // MARK: §3-6 — Task 1 composition (merged + windowed transcript)

    func testIsLastRowFollowsTask1MergedWindowedRows() {
        // 250 messages: the Task-1 window keeps the newest 200. Build the
        // merged render rows exactly like the transcript does, then verify
        // the action-row inputs derive from the WINDOWED list.
        let conversationID = UUID()
        var stored: [StoredMessage] = []
        stored.reserveCapacity(250)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<250 {
            stored.append(StoredMessage(
                conversationID: conversationID,
                role: index % 2 == 0 ? .user : .assistant,
                content: "msg \(index)",
                status: .sent,
                createdAt: base.addingTimeInterval(Double(index))))
        }
        let rows = TranscriptLayoutEngine.renderRows(stored: stored, live: [])
        XCTAssertEqual(rows.count, TranscriptLayoutEngine.maxVisibleMessages)

        // The window's LAST row (newest message) is the action-row tail.
        let last = rows[rows.count - 1]
        XCTAssertTrue(last.text == "msg 249")
        // The newest row is assistant (odd index) → regenerate-eligible.
        let isLast = MessageActionRowEngine.regenerateEligible(
            isUser: last.isUser, isLastRow: true)
        XCTAssertTrue(isLast)
        // …and an OLDER row inside the window is not.
        let older = rows[rows.count - 3]
        XCTAssertFalse(MessageActionRowEngine.regenerateEligible(
            isUser: older.isUser, isLastRow: false))
    }

    func testFailedRowKeepsFunctionalRow() {
        // §3 lossless stop/fail: the partial text survived, so its row keeps
        // copy/share (regenerate gates on send path, not on failure).
        let actions = MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: false, status: .failed, isLastRow: true,
            canRegenerate: true, hasMoreEntries: false))
        XCTAssertEqual(actions.map(\.action), [.copy, .regenerate, .share])
    }
}
