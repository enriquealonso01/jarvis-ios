import XCTest
@testable import FeaturesChat

// MARK: - UI parity: rich actions, poll/form submit state, markdown blocks
//
// Pins the pure layer behind the redesigned renderers (headless, macOS-lane
// safe — no SwiftUI types are touched):
//   UA-1  action routing: openUrl → vetted URL or send-label fallback; copy;
//         every other kind sends its label (never a dead button);
//   UA-2  unsafe URLs never open (javascript:/data: fall back to send);
//   UA-3  poll submit requires a selection and is idempotent (R04);
//   UA-4  one-shot actions / form submit lock after the first fire;
//   UA-5  vote + form message text (labels, Yes/No, unanswered omitted);
//   UA-6  markdown block parser: headings, lists, quotes, fences (incl. an
//         unterminated streaming fence), paragraphs;
//   UA-7  wire decode keeps an action's optional `url`.
final class UIParityRichActionTests: XCTestCase {

    // MARK: UA-1 / UA-2 routing

    func testOpenUrlWithSafeURLOpens() {
        let action = RichBlockAction(id: "a", label: "Open map", kind: .openUrl,
                                     url: "https://example.com/map")
        XCTAssertEqual(RichActionRouter.route(action), .open(URL(string: "https://example.com/map")!))
    }

    func testOpenUrlUsesIdWhenItIsAURL() {
        let action = RichBlockAction(id: "https://example.com", label: "Site", kind: .openUrl)
        XCTAssertEqual(RichActionRouter.route(action), .open(URL(string: "https://example.com")!))
    }

    func testOpenUrlWithoutTargetSendsLabel() {
        let action = RichBlockAction(id: "breck-lift", label: "Buy lift tickets", kind: .openUrl)
        XCTAssertEqual(RichActionRouter.route(action), .send("Buy lift tickets"))
    }

    func testUnsafeSchemesNeverOpen() {
        for raw in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd"] {
            let action = RichBlockAction(id: "x", label: "Tap", kind: .openUrl, url: raw)
            XCTAssertEqual(RichActionRouter.route(action), .send("Tap"), raw)
        }
    }

    func testCopyAndSendKinds() {
        XCTAssertEqual(RichActionRouter.route(
            RichBlockAction(id: "c", label: "Copy code", kind: .copy, url: "ABC-123")), .copy("ABC-123"))
        XCTAssertEqual(RichActionRouter.route(
            RichBlockAction(id: "c", label: "Copy me", kind: .copy)), .copy("Copy me"))
        for kind in [RichBlockAction.Kind.local, .submit, .navigate, .serverAction] {
            let route = RichActionRouter.route(RichBlockAction(id: "s", label: "Do it", kind: kind))
            XCTAssertEqual(route, .send("Do it"))
            XCTAssertTrue(RichActionRouter.isOneShot(route))
        }
        XCTAssertFalse(RichActionRouter.isOneShot(.open(URL(string: "https://a.b")!)))
    }

    func testNeedsConfirmation() {
        XCTAssertFalse(RichBlockAction(id: "a", label: "A", kind: .local).needsConfirmation)
        XCTAssertTrue(RichBlockAction(id: "a", label: "A", kind: .serverAction,
                                      requiresApproval: true).needsConfirmation)
        XCTAssertTrue(RichBlockAction(id: "a", label: "A", kind: .serverAction,
                                      confirmText: "Pause the ad set?").needsConfirmation)
        XCTAssertFalse(RichBlockAction(id: "a", label: "A", kind: .serverAction,
                                       confirmText: "   ").needsConfirmation)
    }

    // MARK: UA-3 / UA-4 interaction state

    @MainActor
    func testPollSubmitNeedsSelectionAndIsIdempotent() {
        let store = RichInteractionStore()
        XCTAssertFalse(store.submitPoll(messageID: "m", blockID: "p"))
        store.selectPoll(messageID: "m", blockID: "p", optionIndex: 1)
        XCTAssertTrue(store.submitPoll(messageID: "m", blockID: "p"))
        XCTAssertTrue(store.isPollSubmitted(messageID: "m", blockID: "p"))
        XCTAssertFalse(store.submitPoll(messageID: "m", blockID: "p"), "second submit must not double-count")
        XCTAssertFalse(store.isPollSubmitted(messageID: "other", blockID: "p"))
        store.reset(messageID: "m")
        XCTAssertFalse(store.isPollSubmitted(messageID: "m", blockID: "p"))
    }

    @MainActor
    func testOneShotActionsAndFormsLock() {
        let store = RichInteractionStore()
        XCTAssertTrue(store.markActionFired(messageID: "m", blockID: "b", actionID: "a"))
        XCTAssertFalse(store.markActionFired(messageID: "m", blockID: "b", actionID: "a"))
        XCTAssertTrue(store.hasFired(messageID: "m", blockID: "b", actionID: "a"))
        XCTAssertFalse(store.hasFired(messageID: "m", blockID: "b", actionID: "z"))
        XCTAssertTrue(store.markFormSubmitted(messageID: "m", blockID: "f"))
        XCTAssertFalse(store.markFormSubmitted(messageID: "m", blockID: "f"))
        store.resetAll()
        XCTAssertFalse(store.hasFired(messageID: "m", blockID: "b", actionID: "a"))
        XCTAssertFalse(store.isFormSubmitted(messageID: "m", blockID: "f"))
    }

    // MARK: UA-5 message text

    func testVoteAndFormText() {
        XCTAssertEqual(RichActionRouter.pollVoteText(question: "Which creative?", option: "Knee-saver v2"),
                       "Vote: Knee-saver v2\n(Which creative?)")
        let fields = [
            RichFormField(id: "budget", kind: .number, label: "Daily budget cap ($)", required: true),
            RichFormField(id: "pause", kind: .checkbox, label: "Pause the unboxing ad set"),
            RichFormField(id: "note", kind: .text, label: "Note"),
        ]
        let text = RichActionRouter.formSubmissionText(
            submitLabel: "Apply changes", fields: fields,
            draft: ["budget": "25", "pause": "1", "note": "  "])
        XCTAssertEqual(text, "Apply changes\n• Daily budget cap ($): 25\n• Pause the unboxing ad set: Yes")
    }

    // MARK: UA-6 markdown

    func testMarkdownBlocks() {
        let source = """
        ### Yesterday — pedal trainer
        - **Spend:** $41.20
        - **Orders:** 3

        Winner is the *knee-saver angle*.
        1. First
        2) Second
        > quoted
        > more
        ---
        ```sql
        SELECT 1;
        ```
        """
        let blocks = MarkdownBlockParser.parse(source)
        XCTAssertEqual(blocks, [
            .heading(level: 3, text: "Yesterday — pedal trainer"),
            .bullet("**Spend:** $41.20"),
            .bullet("**Orders:** 3"),
            .paragraph("Winner is the *knee-saver angle*."),
            .numbered(index: "1", text: "First"),
            .numbered(index: "2", text: "Second"),
            .quote("quoted\nmore"),
            .rule,
            .code(language: "sql", code: "SELECT 1;"),
        ])
    }

    func testStreamingUnterminatedFenceStaysCode() {
        let blocks = MarkdownBlockParser.parse("Here:\n```swift\nlet x = 1")
        XCTAssertEqual(blocks, [.paragraph("Here:"), .code(language: "swift", code: "let x = 1")])
    }

    func testPlainTextIsOneParagraph() {
        XCTAssertEqual(MarkdownBlockParser.parse("Rang Jessica — 4m 12s."), [.paragraph("Rang Jessica — 4m 12s.")])
        XCTAssertFalse(MarkdownBlockParser.hasBlockSyntax("Just text"))
        XCTAssertTrue(MarkdownBlockParser.hasBlockSyntax("# Title"))
        // "#hashtag" is not a heading.
        XCTAssertEqual(MarkdownBlockParser.parse("#hashtag"), [.paragraph("#hashtag")])
    }

    // MARK: UA-7 wire

    func testActionURLRoundTrips() throws {
        let json = #"{"id":"a","label":"Open","kind":"openUrl","url":"https://example.com"}"#
        let action = try JSONDecoder().decode(RichBlockAction.self, from: Data(json.utf8))
        XCTAssertEqual(action.url, "https://example.com")
        let legacy = #"{"id":"a","label":"Open","kind":"openUrl"}"#
        XCTAssertNil(try JSONDecoder().decode(RichBlockAction.self, from: Data(legacy.utf8)).url)
    }
}
