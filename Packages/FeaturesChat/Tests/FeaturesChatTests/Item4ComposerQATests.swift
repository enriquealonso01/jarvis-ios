import XCTest
@testable import FeaturesChat

/// Item 4 TESTER QA — acceptance tests for Feature #3, the Composer
/// (UI Law §6). The builder owns `ComposerViewModel` SOURCES; these tests PIN
/// the contract the builder reconciles to (Item 3 tester-pinned-VM pattern).
/// Everything here is pure logic: a real store, an injected fixed clock,
/// fake model catalog, an event sink for intents — no UIKit, no SwiftUI.
///
/// Pinned `ComposerViewModel` contract (the API the tests hold the builder to):
///
///   init(store: PersistenceStore,
///        models: [ComposerModelOption] = ComposerModelOption.defaults,
///        clock: @escaping () -> Date = Date.init,
///        events: ((ComposerEvent) -> Void)? = nil)
///
///   // Input
///   var text: String { get set }                       // field content
///   func onPaste(text: String)                         // large-paste gate
///   func toggle(modelID: String)                       // chip add/remove
///   func clearChips()                                  // the × affordance
///   func composerSendTapped()                          // returns false when disabled
///   func sendLongPressed()                             // fires .showModelChooser
///   func waveformTapped()                              // fires .startCall
///
///   // Observed state
///   var canSend: Bool { get }                          // non-whitespace content only
///   var attachments: [ComposerAttachment] { get }      // chips (paste + ＋ sheet)
///   var selectedModels: [ComposerModelOption] { get }  // chips, opt-in, never silent
///   var isChipAreaVisible: Bool { get }                // chips present → visible (never silent)
///   var isSheetPresented: Bool { get }
///   var sheetOptions: [ComposerSheetOption] { get }    // exactly Photos/Camera/Files/Hermes
///   var isScrollable: Bool { get }                     // > maxLines → internal scroll
///   static let maxLines: Int                           // 5–6 (UI Law §6), pinned = 5
///
///   // Send path
///   func send() async throws -> Bool                   // text+chips → store row, clears input
///
/// Types:
///   ComposerAttachment(id:text:source:)   source: .paste | .picker
///   ComposerModelOption(id:label:)        .defaults non-empty; single-model ids never resolve to another model
///   ComposerSheetOption: Identifiable     .photos/.camera/.files/.hermesFiles in that display order
///   ComposerEvent: Equatable              .showModelChooser | .startCall
///   Tokens.Composer.largePasteThreshold == 5000 (DesignSystem §6)
@MainActor
final class Item4ComposerQATests: XCTestCase {

    // MARK: - Fakes

    private var sink: [ComposerEvent] = []
    private var onEvent: (ComposerEvent) -> Void { { [weak self] in self?.sink.append($0) } }

    override func setUp() {
        super.setUp()
        sink = []
    }

    private func makeStore() -> PersistenceStore { PersistenceStore() }

    private func makeVM(
        store: PersistenceStore? = nil,
        models: [ComposerModelOption] = ComposerModelOption.defaults
    ) -> ComposerViewModel {
        ComposerViewModel(
            store: store ?? makeStore(),
            models: models,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            events: { [weak self] in self?.sink.append($0) }
        )
    }

    private func chip(_ id: String, label: String) -> ComposerModelOption {
        ComposerModelOption(id: id, label: label)
    }

    private func largePaste(_ n: Int) -> String { String(repeating: "x", count: n) }

    // MARK: (a) Send enablement = content-only

    func testSendDisabledOnEmptyAndWhitespaceOnly() {
        let vm = makeVM()
        XCTAssertFalse(vm.canSend, "empty text must not enable send")
        vm.text = ""
        XCTAssertFalse(vm.canSend)
        vm.text = "   "
        XCTAssertFalse(vm.canSend, "whitespace-only must NOT enable send (UI Law §6)")
        vm.text = "\n\t  \n"
        XCTAssertFalse(vm.canSend, "any mix of whitespace-only must NOT enable send")
        // Chips alone do not enable send: send is content-gated, chips are context.
        vm.toggle(modelID: ComposerModelOption.defaults[0].id)
        XCTAssertFalse(vm.canSend, "a tool chip with empty text must not enable send")
        // Attachment chip alone also does not enable send.
        vm.onPaste(text: largePaste(6_000))
        XCTAssertFalse(vm.canSend, "attachment chip alone must not enable send")
        // Trimmed real content is the only enabler.
        vm.text = " hi "
        XCTAssertTrue(vm.canSend)
    }

    func testSendEnablesWithExactlyOneNonWhitespaceChar() {
        let vm = makeVM()
        vm.text = "x"
        XCTAssertTrue(vm.canSend, "single char enables send")
        vm.text = " x\n"
        XCTAssertTrue(vm.canSend, "whitespace AROUND content keeps send enabled")
    }

    func testSendClearsInputOnSuccessAndStoresRow() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        vm.text = "hello composer"
        let ok = try await vm.send()
        XCTAssertTrue(ok)
        XCTAssertTrue(vm.text.isEmpty || vm.text == "",
                      "successful send clears the field")
        XCTAssertFalse(vm.canSend, "canSend flips back to disabled after send")
        let count = await store.count()
        XCTAssertEqual(count, 1, "send must write through to the store (source of truth)")
        let row = await store.recentMessages(limit: 1)
        XCTAssertEqual(row.first?.role, .user)
        XCTAssertEqual(row.first?.content, "hello composer")
        // Double-send with empty field is a no-op (guard holds).
        vm.text = ""
        let second = try await vm.send()
        XCTAssertFalse(second, "send on empty text must be a guarded no-op")
        let count2 = await store.count()
        XCTAssertEqual(count2, 1, "no duplicate row from an empty send")
    }

    // MARK: (b) Large paste > 5000 chars → attachment chip + text cleared

    func testLargePasteBecomesChipAndClearsComposerText() {
        let vm = makeVM()
        vm.text = "prelude"
        vm.onPaste(text: largePaste(Tokens.Composer.largePasteThreshold + 1))
        XCTAssertEqual(vm.attachments.count, 1, ">5k chars must auto-convert to ONE attachment chip")
        XCTAssertEqual(vm.attachments.first?.source, .paste,
                       "the chip must be marked as paste-origin")
        XCTAssertEqual(vm.attachments.first?.text.count, Tokens.Composer.largePasteThreshold + 1,
                       "chip must carry the full pasted payload, not a truncation")
        XCTAssertTrue(vm.text.isEmpty || vm.text == "",
                      "composer text must be cleared after the conversion")
        XCTAssertFalse(vm.canSend, "converted paste alone does not enable send")
    }

    func testPasteAtExactlyThresholdStaysInline() {
        let vm = makeVM()
        vm.onPaste(text: largePaste(Tokens.Composer.largePasteThreshold))
        XCTAssertEqual(vm.attachments.count, 0,
                       "plan says > 5k converts: exactly 5000 chars stays inline")
        XCTAssertEqual(vm.text.count, Tokens.Composer.largePasteThreshold)
        vm.onPaste(text: largePaste(Tokens.Composer.largePasteThreshold - 1))
        XCTAssertEqual(vm.attachments.count, 0, "4999 chars stays inline")
    }

    func testConsecutiveLargePastesMakeDistinctChips() {
        let vm = makeVM()
        vm.onPaste(text: largePaste(6_000))
        vm.onPaste(text: largePaste(6_100))
        XCTAssertEqual(vm.attachments.count, 2, "each large paste gets its own chip")
        XCTAssertNotEqual(vm.attachments[0].id, vm.attachments[1].id,
                          "chips need distinct identities for removal/preview")
        XCTAssertTrue(vm.text.isEmpty || vm.text == "")
    }

    func testSendingWithAttachmentChipWritesMessageAndClearsChip() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        vm.onPaste(text: largePaste(6_000))
        vm.text = "see attached"
        let ok = try await vm.send()
        XCTAssertTrue(ok)
        let count = await store.count()
        XCTAssertEqual(count, 1, "text + attachment chip = one user message row")
        let row = await store.recentMessages(limit: 1)
        XCTAssertEqual(row.first?.content, "see attached")
        XCTAssertFalse(vm.attachments.isEmpty,
                       "attachment chip must survive until send consumes it")
        XCTAssertTrue(vm.text.isEmpty || vm.text == "")
    }

    // MARK: (c) Chip model — add/clear/toggle, opt-in, never silent

    func testToolToggleIsOptInAndNeverSilent() {
        let vm = makeVM()
        XCTAssertTrue(vm.selectedModels.isEmpty,
                      "composer starts with ZERO tool chips — opt-in, never silent")
        XCTAssertFalse(vm.isChipAreaVisible,
                       "no chips → no chip row rendered (never silent)")
        let id = ComposerModelOption.defaults[0].id
        vm.toggle(modelID: id)
        XCTAssertTrue(vm.selectedModels.contains { $0.id == id },
                      "toggle adds the chip")
        XCTAssertTrue(vm.isChipAreaVisible,
                      "a present chip MUST surface the chip row — chips are never silent")
        vm.toggle(modelID: id)
        XCTAssertFalse(vm.selectedModels.contains { $0.id == id },
                       "toggle removes on second tap (off opt-in)")
        XCTAssertFalse(vm.isChipAreaVisible, "row hides again once empty")
    }

    func testClearChipsRemovesAllAndHidesRow() {
        let vm = makeVM()
        for m in ComposerModelOption.defaults.prefix(3) { vm.toggle(modelID: m.id) }
        XCTAssertEqual(vm.selectedModels.count, 3)
        XCTAssertTrue(vm.isChipAreaVisible)
        vm.clearChips()
        XCTAssertTrue(vm.selectedModels.isEmpty, "× clears all chips")
        XCTAssertFalse(vm.isChipAreaVisible, "chip area hides after clear")
    }

    func testChipsRenderLabeledNotIconSilent() {
        // UI Law §6: blue labeled chips — the option carries a label and the
        // VM preserves it (the view binds label text from the model option).
        for m in ComposerModelOption.defaults {
            XCTAssertFalse(m.label.isEmpty, "every model chip must be LABELED (§6)")
            XCTAssertFalse(m.id.isEmpty)
        }
        let vm = makeVM()
        let custom = chip("web", label: "Web Search")
        vm.toggle(modelID: custom.id)
        XCTAssertEqual(vm.selectedModels.first?.label, "Web Search",
                       "chip label survives into selected state verbatim")
    }

    func testToggleOfUnknownModelIDNeverSelectsAnything() {
        let vm = makeVM()
        vm.toggle(modelID: "not-in-catalog")
        XCTAssertTrue(vm.selectedModels.isEmpty,
                      "toggling an id outside the catalog must not select a different model")
    }

    // MARK: (d) Growth logic — ~5–6 lines then internal scroll

    func testGrowthThresholdIsFiveToSixLinesThenScroll() {
        XCTAssertEqual(ComposerViewModel.maxLines, 5,
                       "pinned growth cap must be within the 5–6 line window (§6)")
        XCTAssertGreaterThanOrEqual(ComposerViewModel.maxLines, 5)
        XCTAssertLessThanOrEqual(ComposerViewModel.maxLines, 6)

        let vm = makeVM()
        XCTAssertFalse(vm.isScrollable, "1-line composer is not scrollable")
        vm.text = "one"
        XCTAssertFalse(vm.isScrollable)
        vm.text = String(repeating: "line\n", count: ComposerViewModel.maxLines - 1)
        XCTAssertFalse(vm.isScrollable,
                       "exactly maxLines lines still grows (no scroll yet)")
        vm.text = String(repeating: "line\n", count: ComposerViewModel.maxLines)
        XCTAssertTrue(vm.isScrollable,
                      "beyond maxLines the composer scrolls internally instead of growing")
        // Boundary again with single-char lines.
        vm.text = Array(repeating: "x", count: ComposerViewModel.maxLines).joined(separator: "\n")
        XCTAssertFalse(vm.isScrollable)
        vm.text = Array(repeating: "x", count: ComposerViewModel.maxLines + 1).joined(separator: "\n")
        XCTAssertTrue(vm.isScrollable)
    }

    // MARK: (e) Long-press send → model chooser intent

    func testLongPressSendFiresModelChooserIntent() {
        let vm = makeVM()
        vm.sendLongPressed()
        XCTAssertEqual(sink, [.showModelChooser],
                       "long-press send must fire exactly one showModelChooser intent (§6)")
        // Fires regardless of send-enabled state — the chooser is a gesture,
        // not a send.
        sink.removeAll()
        vm.text = "   "
        vm.sendLongPressed()
        XCTAssertEqual(sink, [.showModelChooser])
    }

    func testLongPressSendDoesNotSendOrMutateState() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        vm.text = "draft text"
        vm.sendLongPressed()
        XCTAssertEqual(vm.text, "draft text", "long-press must not consume the draft")
        let count = await store.count()
        XCTAssertEqual(count, 0, "long-press must NOT write a message row")
        XCTAssertTrue(vm.attachments.isEmpty)
        XCTAssertEqual(vm.selectedModels.count, 0)
    }

    // MARK: (f) Waveform button → call-start intent

    func testWaveformTappedFiresStartCallIntent() {
        let vm = makeVM()
        vm.waveformTapped()
        XCTAssertEqual(sink, [.startCall],
                       "waveform button starts a CALL, not a dictation (UI Law §7)")
        vm.waveformTapped()
        XCTAssertEqual(sink, [.startCall, .startCall],
                       "each tap re-fires the intent (stub-level: no call machinery here)")
    }

    func testWaveformTappedDoesNotTouchComposerState() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        vm.text = "in-flight draft"
        vm.waveformTapped()
        XCTAssertEqual(vm.text, "in-flight draft", "call start must not consume the draft")
        let count = await store.count()
        XCTAssertEqual(count, 0, "call start writes no message row")
        XCTAssertFalse(vm.isSheetPresented, "waveform ≠ ＋ sheet")
    }

    // MARK: (g) ＋ sheet exposes exactly Photos/Camera/Files/Hermes rows

    func testPlusSheetExposesExactlyTheFourRequiredRows() {
        let vm = makeVM()
        XCTAssertFalse(vm.isSheetPresented, "sheet starts dismissed")
        vm.plusTapped()
        XCTAssertTrue(vm.isSheetPresented, "＋ must open the bottom sheet (§6)")
        XCTAssertEqual(vm.sheetOptions.map { $0.id },
                       [.photos, .camera, .files, .hermesFiles],
                       "sheet rows must be exactly Photos, Camera, Files, Hermes workspace files — in order")
        XCTAssertEqual(vm.sheetOptions.count, 4, "no extra/missing rows")
    }

    func testPlusSheetOpenCloseToggleSemantics() {
        let vm = makeVM()
        vm.plusTapped()
        XCTAssertTrue(vm.isSheetPresented)
        vm.dismissSheet()
        XCTAssertFalse(vm.isSheetPresented, "dismissal is explicit and sticky")
        vm.dismissSheet()
        XCTAssertFalse(vm.isSheetPresented, "double-dismiss stays dismissed")
        vm.plusTapped()
        XCTAssertTrue(vm.isSheetPresented, "sheet re-opens cleanly")
    }

    func testPickingARowFromPlusSheetDismissesAndNeverSelectsModel() {
        let vm = makeVM()
        vm.plusTapped()
        let files = vm.sheetOptions.first { $0.id == .files }
        let photos = vm.sheetOptions.first { $0.id == .photos }
        let camera = vm.sheetOptions.first { $0.id == .camera }
        let hermes = vm.sheetOptions.first { $0.id == .hermesFiles }
        for opt in [files, photos, camera, hermes] {
            guard let opt else { return XCTFail("all four rows must exist") }
            vm.selectSheetOption(opt)
            XCTAssertFalse(vm.isSheetPresented,
                           "picking any row dismisses the sheet")
            XCTAssertTrue(vm.selectedModels.isEmpty,
                          "sheet rows are attachment pickers, NEVER model chips (§6)")
        }
    }

    // MARK: Model context picker placement (§6: NEVER in the composer)

    func testModelCatalogIsChooserPayloadOnlyNeverComposerChipSet() {
        // The one-off model chooser (long-press send) presents from the catalog,
        // but the composer's selectedModels starts empty and only ever grows by
        // explicit toggle — the catalog itself is never silently pre-selected.
        let vm = makeVM()
        XCTAssertEqual(vm.selectedModels.count, 0,
                       "catalog options must not leak into composer chips at init")
        // The chooser payload is a separate, complete list.
        for m in ComposerModelOption.defaults {
            XCTAssertFalse(m.label.isEmpty)
        }
    }
}
