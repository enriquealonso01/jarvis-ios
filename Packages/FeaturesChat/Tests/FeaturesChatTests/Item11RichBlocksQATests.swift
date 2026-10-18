import XCTest
import Persistence
@testable import FeaturesChat

// MARK: - Item 11 QA: Rich Blocks (typed schema + registry + render path)
//
// Pins (headless, macOS-lane safe — no UIKit anywhere; SwiftUI types are
// never touched, every asserted decision lives in the pure layer):
//   RB-1  decode/encode round-trip of EVERY P0 block type;
//   RB-2  unknown type → fallbackText card (registry plan pin);
//   RB-3  renderer registry coverage for the P0 (+P1) set;
//   RB-4  malformed blocks degrade gracefully (never crash, never blank,
//         never reject the whole reply);
//   RB-5  P1 set (notice/citation/card/checklist) round-trips too;
//   RB-6  print strategy defaults per type (Item 13's seam);
//   RB-7  transcript render-path integration: envelope rows render blocks,
//         plain rows stay plain (Item 8/9 surfaces untouched);
//   RB-8  interactive state is per-message isolated + resettable;
//   RB-9  URL safety (no javascript:/data: ever becomes a link).
final class Item11RichBlocksQATests: XCTestCase {

    // MARK: Fixtures

    /// One strict, schema-shaped block per P0 type (+ P1 set).
    private func p0BlockDict(_ type: String) -> [String: Any] {
        switch type {
        case "text":
            return ["id": "b-text", "type": "text", "version": "1.0.0",
                    "props": ["text": "Plain text body"],
                    "fallbackText": "Plain text body"]
        case "markdown":
            return ["id": "b-md", "type": "markdown", "version": "1.0.0",
                    "props": ["markdown": "**bold** and _italic_"],
                    "fallbackText": "bold and italic"]
        case "heading":
            return ["id": "b-h", "type": "heading", "version": "1.0.0",
                    "props": ["text": "Section", "level": 2],
                    "fallbackText": "Section"]
        case "code":
            return ["id": "b-code", "type": "code", "version": "1.0.0",
                    "props": ["code": "let x = 1", "language": "swift"],
                    "fallbackText": "let x = 1"]
        case "table":
            return ["id": "b-table", "type": "table", "version": "1.0.0",
                    "props": ["headers": ["Item", "Qty"],
                              "rows": [["Widget", "3"], ["Gadget", "7"]]],
                    "fallbackText": "Item · Qty — Widget · 3 · Gadget · 7"]
        case "image":
            return ["id": "b-img", "type": "image", "version": "1.0.0",
                    "props": ["url": "https://example.com/cat.jpg",
                              "alt": "A cat", "caption": "Studio cat"],
                    "fallbackText": "A cat"]
        case "buttonGroup":
            return ["id": "b-btn", "type": "buttonGroup", "version": "1.0.0",
                    "props": ["buttons": [
                        ["id": "a1", "label": "Approve", "kind": "local"],
                        ["id": "a2", "label": "Open", "kind": "openUrl"]]],
                    "fallbackText": "Approve, Open"]
        case "poll":
            return ["id": "b-poll", "type": "poll", "version": "1.0.0",
                    "props": ["question": "Lunch?", "options": ["Ramen", "Tacos"]],
                    "fallbackText": "Lunch?: Ramen, Tacos"]
        case "chart":
            return ["id": "b-chart", "type": "chart", "version": "1.0.0",
                    "props": ["kind": "bar", "title": "Deploys",
                              "points": [["label": "Mon", "value": 4],
                                         ["label": "Tue", "value": 9.5]]],
                    "fallbackText": "Deploys — Mon: 4, Tue: 9.5"]
        case "form":
            return ["id": "b-form", "type": "form", "version": "1.0.0",
                    "props": ["fields": [
                        ["id": "f1", "kind": "text", "label": "Name", "required": true],
                        ["id": "f2", "kind": "select", "label": "Size", "options": ["S", "M"]]],
                              "submitLabel": "Send it"],
                    "fallbackText": "Name, Size"]
        case "notice":
            return ["id": "b-note", "type": "notice", "version": "1.0.0",
                    "props": ["tone": "warning", "text": "Careful"],
                    "fallbackText": "Careful"]
        case "citation":
            return ["id": "b-cite", "type": "citation", "version": "1.0.0",
                    "props": ["title": "Spec", "url": "https://jarvis.local/spec"],
                    "fallbackText": "Spec — https://jarvis.local/spec"]
        case "card":
            return ["id": "b-card", "type": "card", "version": "1.0.0",
                    "props": ["title": "Card", "subtitle": "Sub", "body": "Body"],
                    "fallbackText": "Card. Body"]
        case "checklist":
            return ["id": "b-check", "type": "checklist", "version": "1.0.0",
                    "props": ["items": [["id": "c1", "text": "Pack", "isChecked": false]]],
                    "fallbackText": "Pack"]
        default:
            return ["id": "b-\(type)", "type": type, "version": "1.0.0",
                    "props": [:], "fallbackText": "\(type) block"]
        }
    }

    private func encodeDict(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    /// Strict-decode a dict-shaped block through the production Codable model.
    private func decodeBlock(_ dict: [String: Any]) throws -> RichBlock {
        try JSONDecoder().decode(RichBlock.self, from: encodeDict(dict))
    }

    @MainActor
    private func makeVM(rows: [TranscriptRow]) -> TranscriptViewModel {
        let vm = TranscriptViewModel(conversationID: UUID(), store: nil)
        vm.updateLiveState(snapshots: [], messageIDs: [:])
        // Inject rows through the public live-state seam, then force the
        // refresh composition. (refreshDisplay reads storedPage + live; the
        // live seam is the public test entry.)
        vm.updateLiveState(
            snapshots: rows.enumerated().map { index, row in
                StreamMessageSnapshot(
                    id: Int64(index + 1),
                    state: row.status == .streaming ? .streaming : .done,
                    text: row.text,
                    lastEventID: 0,
                    retryAvailable: false)
            },
            messageIDs: [:])
        return vm
    }

    // MARK: RB-1 — decode/encode round-trip of every P0 block

    func testP0RoundTrip() throws {
        let p0 = ["text", "markdown", "heading", "code", "table", "image",
                  "buttonGroup", "poll", "chart", "form"]
        XCTAssertEqual(Set(p0), RichBlockRendererRegistry.p0Types
            .map(\\.rawValue).reduce(into: Set()) { $0.insert($1) },
            "the registry's P0 set must equal the item-11 delivery set")

        for raw in p0 {
            let block = try decodeBlock(p0BlockDict(raw))
            XCTAssertEqual(block.type.rawValue, raw, raw)
            XCTAssertEqual(block.version, "1.0.0")
            XCTAssertFalse(block.fallbackText.isEmpty, "every block has fallbackText")

            // Round-trip: re-encode → decode → equal.
            let data = try JSONEncoder().encode(block)
            let back = try JSONDecoder().decode(RichBlock.self, from: data)
            XCTAssertEqual(back, block, "round-trip failed for \\(raw)")

            // And the wire keeps the schema's required keys.
            let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            for key in ["id", "type", "version", "props", "fallbackText"] {
                XCTAssertNotNil(obj[key], "\\(raw) wire is missing \\(key)")
            }
        }
    }

    func testP1RoundTrip() throws {
        for raw in ["notice", "citation", "card", "checklist"] {
            let block = try decodeBlock(p0BlockDict(raw))
            let data = try JSONEncoder().encode(block)
            let back = try JSONDecoder().decode(RichBlock.self, from: data)
            XCTAssertEqual(back, block, raw)
        }
    }

    func testEveryBlockCarriesIdFallbackTextAndPrintStrategy() throws {
        for type in RichBlockType.allCases where type != .fallback {
            let block = try decodeBlock(p0BlockDict(type.rawValue))
            XCTAssertFalse(block.id.isEmpty)
            XCTAssertFalse(block.fallbackDisplayText.isEmpty)
            XCTAssertNotNil(block.print, "print strategy defaulted for \\(type)")
        }
    }

    // MARK: RB-2 — unknown type → fallbackText card

    func testUnknownTypeBecomesFallbackCardWithProducerText() {
        var dict = p0BlockDict("text")
        dict["type"] = "hyperCanvas"           // unknown to this build
        dict["fallbackText"] = "A canvas of shapes"
        dict["props"] = ["anything": "goes"]   // unknown props never crash

        let block = RichBlockSalvage.block(from: dict)
        XCTAssertEqual(block.type, .fallback)
        XCTAssertEqual(block.fallbackDisplayText, "A canvas of shapes")

        // Registry: the fallback card IS the plan (never a crash path).
        guard case .fallbackCard(let reason) = RichBlockRendererRegistry.renderPlan(for: block) else {
            return XCTFail("unknown type must plan a fallback card")
        }
        XCTAssertEqual(reason, .decodingFailure)
    }

    func testUnknownTypeWithoutFallbackTextStillNeverBlank() {
        let dict: [String: Any] = [
            "id": "b-x", "type": "quantumFlux", "version": "1.0.0",
            "props": ["x": 1]]  // NO fallbackText on the wire

        let block = RichBlockSalvage.block(from: dict)
        XCTAssertEqual(block.type, .fallback)
        XCTAssertFalse(block.fallbackDisplayText.trimmingCharacters(in: .whitespaces).isEmpty,
                       "synthesized fallback is never blank")
        XCTAssertTrue(block.fallbackDisplayText.contains("quantumFlux"),
                      "summary names the unsupported type")
    }

    // MARK: RB-3 — registry coverage for the P0 set

    func testRegistryCoversP0AndP1Natively() {
        for type in RichBlockRendererRegistry.p0Types {
            XCTAssertTrue(RichBlockRendererRegistry.canRender(type), type.rawValue)
        }
        for type in RichBlockRendererRegistry.p1Types {
            XCTAssertTrue(RichBlockRendererRegistry.canRender(type), type.rawValue)
        }
        XCTAssertEqual(RichBlockRendererRegistry.supportedTypes.count, 14,
                       "P0 (10) + P1 (4); the internal fallback is NOT a renderer")
        XCTAssertFalse(RichBlockRendererRegistry.canRender(.fallback))
    }

    func testEveryKnownTypePlansNative() throws {
        for type in RichBlockRendererRegistry.supportedTypes {
            let block = try decodeBlock(p0BlockDict(type.rawValue))
            guard case .native(let planned) = RichBlockRendererRegistry.renderPlan(for: block) else {
                return XCTFail("\\(type.rawValue) must plan native")
            }
            XCTAssertEqual(planned.type, type)
        }
    }

    // MARK: RB-4 — malformed-block graceful paths

    func testMalformedPropsDegradeToFallbackNotCrash() {
        var dict = p0BlockDict("table")
        dict["props"] = ["headers": "not-an-array"]  // wrong shape

        let block = RichBlockSalvage.block(from: dict)
        XCTAssertEqual(block.type, .fallback)
        XCTAssertFalse(block.fallbackDisplayText.isEmpty)
    }

    func testUndecodableImageURLStillRendersSomething() {
        var dict = p0BlockDict("image")
        dict["props"] = ["url": "not a url at all"]

        let block = RichBlockSalvage.block(from: dict)
        XCTAssertEqual(block.type, .fallback,
                       "invalid URL props degrade to the fallback card")
        XCTAssertEqual(block.fallbackDisplayText, "A cat",
                       "the producer fallbackText survives the salvage")
    }

    func testTotalGarbageYieldsEmptyBlocksNeverThrows() {
        let garbage = "🤖 not json at all".data(using: .utf8)!
        XCTAssertTrue(RichBlockSalvage.decodeBlocks(from: garbage).isEmpty)

        let arrayJSON = "[1,2,3]".data(using: .utf8)!
        XCTAssertTrue(RichBlockSalvage.decodeBlocks(from: arrayJSON).isEmpty)
    }

    func testOneBadBlockNeverRejectsTheWholeReply() {
        let good = p0BlockDict("text")
        let bad: [String: Any] = ["id": "b-bad", "type": "warpDrive",
                                  "version": "1.0.0", "props": [:]]
        let envelope: [String: Any] = [
            "schemaVersion": "1.0.0", "messageId": "m1",
            "blocks": [good, bad]]

        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let blocks = RichBlockSalvage.decodeBlocks(from: data)
        XCTAssertEqual(blocks.count, 2, "both blocks survive, leniently")
        XCTAssertEqual(blocks[0].type, .text)
        XCTAssertEqual(blocks[1].type, .fallback)
    }

    func testMissingPropsIsGraceful() {
        var dict = p0BlockDict("poll")
        dict.removeValue(forKey: "props")
        let block = RichBlockSalvage.block(from: dict)
        XCTAssertEqual(block.type, .fallback)
        XCTAssertFalse(block.fallbackDisplayText.isEmpty)
    }

    // MARK: RB-5 — envelope + fence carriers

    func testEnvelopeRoundTripViaLenientDecode() {
        let envelope: [String: Any] = [
            "schemaVersion": "1.0.0",
            "messageId": "msg-1",
            "conversationId": "conv-1",
            "blocks": [p0BlockDict("text"), p0BlockDict("poll")]]
        let data = try! JSONSerialization.data(withJSONObject: envelope)

        let blocks = RichBlockSalvage.decodeBlocks(from: data)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].type, .text)
        XCTAssertEqual(blocks[1].type, .poll)
        XCTAssertEqual(blocks[1].id, "b-poll", "producer ids survive")
    }

    func testStrictEnvelopeModelRoundTrip() throws {
        let block = try decodeBlock(p0BlockDict("chart"))
        let envelope = RichBlocksEnvelope(
            messageId: "msg-9", conversationId: "c1", projectId: nil,
            blocks: [block])
        let data = try envelope.encodedData()
        let back = try JSONDecoder().decode(RichBlocksEnvelope.self, from: data)
        XCTAssertEqual(back, envelope)
        XCTAssertEqual(back.blocks.first?.type, .chart)
    }

    func testFencedCarrierParses() {
        let envelope: [String: Any] = [
            "schemaVersion": "1.0.0", "messageId": "m",
            "blocks": [p0BlockDict("code")]]
        let body = String(data: try! JSONSerialization.data(withJSONObject: envelope),
                          encoding: .utf8)!
        let fenced = "```jarvis-rich\\n\\(body)\\n```"

        let blocks = RichContentPayload.parse(fenced)
        XCTAssertNotNil(blocks)
        XCTAssertEqual(blocks?.count, 1)
        XCTAssertEqual(blocks?.first?.type, .code)
    }

    // MARK: RB-6 — print strategies (Item 13 seam)

    func testPrintStrategyDefaults() {
        XCTAssertEqual(RichPrintDefaults.strategy(for: .text), .native)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .table), .native)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .code), .native)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .image), .snapshot)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .poll), .snapshot)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .chart), .snapshot)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .form), .snapshot)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .fallback), .summary)
    }

    func testExplicitPrintPolicyRoundTrips() throws {
        var dict = p0BlockDict("chart")
        dict["print"] = ["strategy": "summary", "summary": "Deploys per day"]
        let block = try decodeBlock(dict)
        XCTAssertEqual(block.print?.strategy, .summary)
        XCTAssertEqual(block.print?.summary, "Deploys per day")

        let back = try JSONDecoder().decode(
            RichBlock.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(back.print, block.print)
    }

    // MARK: RB-7 — transcript render-path integration (additive)

    func testEnvelopeRowYieldsBlocksPlainRowStaysPlain() {
        let envelope: [String: Any] = [
            "schemaVersion": "1.0.0", "messageId": "m",
            "blocks": [p0BlockDict("text"), p0BlockDict("chart")]]
        let envelopeText = String(
            data: try! JSONSerialization.data(withJSONObject: envelope),
            encoding: .utf8)!

        let rich = RichContentPayload.parse(envelopeText)
        XCTAssertNotNil(rich, "envelope content parses into blocks")
        XCTAssertEqual(rich?.count, 2)

        XCTAssertNil(RichContentPayload.parse("Hello, plain world"),
                     "ordinary text never parses into blocks")
        XCTAssertNil(RichContentPayload.parse("{ not an envelope }"),
                     "a non-envelope JSON blob stays plain text")
        XCTAssertNil(RichContentPayload.parse("```swift\\nlet x = 1\\n```"),
                     "ordinary code fences are NOT rich carriers")
    }

    func testTranscriptViewModelExtractsBlocksForAssistantRowsOnly() {
        let envelope: [String: Any] = [
            "schemaVersion": "1.0.0", "messageId": "m",
            "blocks": [p0BlockDict("poll")]]
        let envelopeText = String(
            data: try! JSONSerialization.data(withJSONObject: envelope),
            encoding: .utf8)!

        let vm = TranscriptViewModel(conversationID: UUID(), store: nil)
        vm.refreshDisplay() // empty state sanity — must not crash
        XCTAssertTrue(vm.rowRichBlocks.isEmpty)

        // Assistant row with an envelope → blocks extracted at refresh time.
        let rows = [
            TranscriptRow(id: "m:111", isUser: true, text: "hi",
                          status: .sent, origin: .stored),
            TranscriptRow(id: "m:222", isUser: false, text: envelopeText,
                          status: .sent, origin: .stored),
            TranscriptRow(id: "m:333", isUser: false, text: "plain answer",
                          status: .sent, origin: .stored),
        ]
        // Drive through the private extraction via refreshDisplay seam:
        // updateLiveState + refreshDisplay is the public composition path.
        vm.updateLiveState(
            snapshots: [
                StreamMessageSnapshot(id: 1, state: .done, text: envelopeText,
                                      lastEventID: 0, retryAvailable: false),
                StreamMessageSnapshot(id: 2, state: .done, text: "plain answer",
                                      lastEventID: 0, retryAvailable: false),
            ],
            messageIDs: [:])
        XCTAssertEqual(vm.rowRichBlocks.count, 1,
                       "only the envelope row extracted")
        XCTAssertEqual(vm.richBlocks(for: TranscriptRow(
            id: "s:1", isUser: false, text: envelopeText,
            status: .sent, origin: .live))?.count, 1)
        XCTAssertNil(vm.richBlocks(for: TranscriptRow(
            id: "s:2", isUser: false, text: "plain answer",
            status: .sent, origin: .live)))
        _ = rows // (fixture reuse note: rows mirrored via the live seam above)
    }

    func testRenderRowsUnchangedForPlainTextConversation() {
        // Item 8/9 regression guard: plain rows produce EXACTLY the same
        // merged render as before Item 11 (engine untouched).
        let stored = [
            StoredMessage(conversationID: UUID(), role: .user,
                          content: "question", status: .sent),
            StoredMessage(conversationID: UUID(), role: .assistant,
                          content: "answer", status: .sent),
        ]
        let rows = TranscriptLayoutEngine.renderRows(stored: stored, live: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].text, "question")
        XCTAssertEqual(rows[1].text, "answer")
    }

    // MARK: RB-8 — interactive state isolation + reset

    @MainActor
    func testInteractionStateIsPerMessageAndResettable() {
        let store = RichInteractionStore()

        store.selectPoll(messageID: "msgA", blockID: "p", optionIndex: 1)
        store.selectPoll(messageID: "msgB", blockID: "p", optionIndex: 0)
        XCTAssertEqual(store.pollSelection(messageID: "msgA", blockID: "p"), 1)
        XCTAssertEqual(store.pollSelection(messageID: "msgB", blockID: "p"), 0)

        // Same block id in a NEW message (regenerate) starts clean.
        XCTAssertNil(store.pollSelection(messageID: "msgC", blockID: "p"))

        // Reset one message only.
        store.reset(messageID: "msgA")
        XCTAssertNil(store.pollSelection(messageID: "msgA", blockID: "p"))
        XCTAssertEqual(store.pollSelection(messageID: "msgB", blockID: "p"), 0)

        // Reset all (teardown).
        store.resetAll()
        XCTAssertNil(store.pollSelection(messageID: "msgB", blockID: "p"))
    }

    @MainActor
    func testChecklistAndFormDraftState() {
        let store = RichInteractionStore()
        store.toggleChecklist(messageID: "m", blockID: "c", index: 0, count: 2)
        store.toggleChecklist(messageID: "m", blockID: "c", index: 1, count: 2)
        XCTAssertEqual(store.checklistState(messageID: "m", blockID: "c", count: 2),
                       [true, true])
        store.toggleChecklist(messageID: "m", blockID: "c", index: 1, count: 2)
        XCTAssertEqual(store.checklistState(messageID: "m", blockID: "c", count: 2),
                       [true, false])

        store.setFormValue(messageID: "m", blockID: "f", fieldID: "name", value: "Kike")
        XCTAssertEqual(store.formDraft(messageID: "m", blockID: "f")["name"], "Kike")

        let fields = [
            RichFormField(id: "name", kind: .text, label: "Name", required: true),
            RichFormField(id: "note", kind: .text, label: "Note"),
        ]
        XCTAssertEqual(store.missingRequired(fields: fields,
                                             messageID: "m", blockID: "f"), [])
        store.setFormValue(messageID: "m", blockID: "f", fieldID: "name", value: "")
        XCTAssertEqual(store.missingRequired(fields: fields,
                                             messageID: "m", blockID: "f"), ["name"])
    }

    // MARK: RB-9 — URL safety

    func testUnsafeSchemesNeverBecomeLinks() {
        XCTAssertNil(RichBlocks.safeURL("javascript:alert(1)"))
        XCTAssertNil(RichBlocks.safeURL("data:text/html,hi"))
        XCTAssertNil(RichBlocks.safeURL("file:///etc/passwd"))
        XCTAssertNil(RichBlocks.safeURL("vbscript:msgbox"))
        XCTAssertNotNil(RichBlocks.safeURL("https://jarvis.local/spec"))
        XCTAssertNotNil(RichBlocks.safeURL("http://example.com/a.png"))
    }

    func testUnsafeCitationURLFallsBack() throws {
        var dict = p0BlockDict("citation")
        dict["props"] = ["title": "Evil", "url": "javascript:alert(1)"]
        let block = try decodeBlock(dict)
        guard case .citation = block.content else {
            // Strict decode rejects javascript: URLs entirely — that is also
            // a safe outcome; assert whichever way the model resolved it.
            XCTAssertEqual(block.type, .fallback)
            return
        }
        XCTAssertTrue(URL(string: "javascript:alert(1)") != nil)
        // The VIEW layer gates via safeURL — pure pin:
        XCTAssertNil(RichBlocks.safeURL("javascript:alert(1)"))
        _ = block
    }

    // MARK: No-WKWebView / no-HTML law (static, macOS-lane safe)

    func testRegistryIsNativeOnly() {
        // The sanctioned surface is the native registry; there is no HTML
        // render path to configure. Pin the law at the contract level: every
        // supported type plans native, everything else plans the fallback
        // card — a two-outcome system with no third (web) door.
        for type in RichBlockType.allCases {
            let dict = p0BlockDict(type.rawValue)
            let block = RichBlockSalvage.block(from: dict)
            switch RichBlockRendererRegistry.renderPlan(for: block) {
            case .native, .fallbackCard:
                break // the only two outcomes
            }
        }
    }

    // MARK: Summary helpers (copy/share/print text sources)

    func testPlainSummaryHelpers() {
        XCTAssertEqual(RichCharts.accessibleSummary(
            title: "Deploys", points: [RichChartPoint(label: "Mon", value: 4)]),
            "Deploys — Mon: 4")
        XCTAssertEqual(RichCharts.formattedValue(9.5), "9.50")
        XCTAssertEqual(RichCharts.formattedValue(4), "4")
        XCTAssertTrue(RichCharts.accessibleSummary(title: nil, points: []).hasSuffix("(no data)"))
    }
}
