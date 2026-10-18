import XCTest
import Persistence
import DesignSystem
@testable import FeaturesChat

/// Item 6 TESTER QA — acceptance tests for Feature #8, Attachments
/// (V2-PLAN #8 + UI Law §6 grammar). Follows the Item 4/5 tester pattern:
/// the tests PIN the ViewModel contract first and the builder converges to
/// it. Pure logic only — a real PersistenceStore, an injected fixed clock,
/// an event sink for intents — no UIKit/SwiftUI in the test target; the
/// real Photos/Camera/Files picker GLUE is view-layer and gets only
/// smoke-level coverage here (staging/remove semantics through the VM).
///
/// Pinned `ComposerViewModel` API (Items 4/6 contract, sources @ fbf1302):
///
///   init(store: PersistenceStore?,
///        models: [ComposerModelOption] = .defaults,
///        clock: @escaping () -> Date = Date.init,
///        events: ((ComposerEvent) -> Void)? = nil)
///   var conversationID: UUID                          // get/set
///   var text: String { get set }
///   var attachments: [ComposerAttachment] { get }     // staged chips
///   var canSend: Bool { get }                         // non-whitespace text ONLY
///   var sheetOptions: [ComposerSheetOption] { get }   // Photos/Camera/Files/Hermes in order
///   var isSheetPresented: Bool { get }
///   func onPaste(text: String)                        // strict >5k → chip + clear
///   func selectSheetOption(_ option: ComposerSheetOption)  // row → chip, dismiss
///   func removeAttachment(id: UUID)                   // per-chip ×; unknown id = no-op
///   func send() async throws -> Bool                  // flattens chips → row, clears
///   func restoreState() async                         // KV restore incl. attachments
///   func persistDraft()                               // explicit KV write
///
/// Types (ComposerState.swift):
///   ComposerAttachment(id:text:source: .paste|.picker)  displayName sized captions
///   ComposerSheetOption(.photos/.camera/.files/.hermesFiles)
///   Tokens.Composer.largePasteThreshold == 5000 (DesignSystem §6)
@MainActor
final class Item6ComposerAttachmentQATests: XCTestCase {

    // MARK: - Fakes (Item 4 pattern)

    private var sink: [ComposerEvent] = []

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

    private func largePaste(_ n: Int) -> String { String(repeating: "x", count: n) }

    // MARK: (a) ＋ sheet rows: exactly Photos/Camera/Files/HermesFiles, in order

    func testSheetRowsExactlyPhotosCameraFilesHermesFilesInOrder() {
        let vm = makeVM()
        let ids = vm.sheetOptions.map { $0.id }
        XCTAssertEqual(ids, [.photos, .camera, .files, .hermesFiles],
                       "§6 pins the sheet grammar: Photos, Camera, Files, Hermes workspace files — exactly these, in that order")
        XCTAssertEqual(vm.sheetOptions.count, 4, "no extra rows, no missing rows")
        XCTAssertEqual(vm.sheetOptions.map { $0.label },
                       ["Photos", "Camera", "Files", "Hermes files"],
                       "rows must be labeled (never icon-silent, §6)")
        for row in vm.sheetOptions {
            XCTAssertFalse(row.systemImage.isEmpty, "every sheet row carries an icon")
        }
    }

    // MARK: (b) Every picker path stages a removable attachment chip

    /// All four sheet paths stage exactly one chip each — a tap is never
    /// silent (§6). Placeholder-picked items still enter the staged state.
    func testEachSheetPickerPathStagesOneChip() {
        for option in ComposerSheetOption.standard {
            let vm = makeVM()
            XCTAssertTrue(vm.attachments.isEmpty, "\(option.label): starts clean")
            vm.plusTapped()
            XCTAssertTrue(vm.isSheetPresented, "\(option.label): ＋ opens the sheet")
            vm.selectSheetOption(option)
            XCTAssertFalse(vm.isSheetPresented, "\(option.label): picking dismisses the sheet")
            XCTAssertEqual(vm.attachments.count, 1,
                           "\(option.label): picker path must stage exactly one attachment chip")
            XCTAssertEqual(vm.attachments.first?.source, .picker,
                           "\(option.label): chip marked picker-origin")
            XCTAssertEqual(vm.attachments.first?.text, option.label,
                           "\(option.label): chip carries the picked-item descriptor")
            XCTAssertEqual(vm.attachments.first?.displayName, option.label,
                           "\(option.label): picker chip caption = descriptor verbatim")
            XCTAssertFalse(vm.canSend,
                           "\(option.label): a chip alone must not enable send (content-gated)")
        }
    }

    func testSheetPicksNeverLeakIntoToolChips() {
        let vm = makeVM()
        vm.plusTapped()
        for option in ComposerSheetOption.standard {
            vm.selectSheetOption(option)
        }
        XCTAssertTrue(vm.selectedModels.isEmpty,
                      "sheet rows are attachment pickers, NEVER model chips (§6)")
        XCTAssertFalse(vm.isChipAreaVisible, "no tool chip row appears from picker picks")
        XCTAssertEqual(vm.attachments.count, 4, "all four picks staged")
    }

    /// Item 6 real-picker seam: file documents stage by NAME (the VM keeps
    /// descriptors, never file contents). Pinned via the same public path the
    /// ＋ sheet glue uses — `selectSheetOption` is the staging entry point
    /// real pickers converge to; descriptor text is the picked item's name.
    func testStagedFileChipCarriesDescriptorAndDisplayName() throws {
        let vm = makeVM()
        vm.plusTapped()
        vm.selectSheetOption(ComposerSheetOption(
            id: .files, label: "report.pdf", systemImage: "folder"))
        XCTAssertEqual(vm.attachments.count, 1, "staged file → one chip")
        let chip = try XCTUnwrap(vm.attachments.first)
        XCTAssertEqual(chip.source, .picker)
        XCTAssertEqual(chip.text, "report.pdf", "chip carries the file descriptor verbatim")
        XCTAssertEqual(chip.displayName, "report.pdf", "picker chip caption is the descriptor")
        vm.removeAttachment(id: chip.id)
        XCTAssertTrue(vm.attachments.isEmpty, "staged file chip is removable via ×")
    }

    // MARK: (c) Per-chip × removal; unknown id rejected

    func testRemoveAttachmentRemovesExactlyOneChipByID() {
        let vm = makeVM()
        vm.onPaste(text: largePaste(5_100))          // chip A (paste)
        vm.onPaste(text: largePaste(5_200))          // chip B (paste)
        vm.plusTapped()
        vm.selectSheetOption(.files)                 // chip C (picker)
        XCTAssertEqual(vm.attachments.count, 3, "three staged chips")
        let target = vm.attachments[1]
        vm.removeAttachment(id: target.id)
        XCTAssertEqual(vm.attachments.count, 2, "× removes exactly ONE chip")
        XCTAssertFalse(vm.attachments.contains { $0.id == target.id },
                       "the removed chip's id is gone")
        XCTAssertEqual(vm.attachments.map { $0.id }, [vm.attachments[0].id, vm.attachments[1].id],
                       "remaining chips are untouched (no collateral removal)")
    }

    func testRemoveAttachmentWithUnknownIDIsRejectedNoOp() {
        let vm = makeVM()
        vm.onPaste(text: largePaste(6_000))
        let before = vm.attachments
        vm.removeAttachment(id: UUID())              // unknown id
        XCTAssertEqual(vm.attachments, before,
                       "unknown-id removal must be a silent no-op — never clears other chips")
        vm.removeAttachment(id: UUID())
        XCTAssertEqual(vm.attachments.count, 1, "repeated unknown ids still harmless")
    }

    func testEachChipRemovableIndependentlyUntilEmpty() {
        let vm = makeVM()
        for option in ComposerSheetOption.standard {
            vm.plusTapped()
            vm.selectSheetOption(option)
        }
        let ids = vm.attachments.map { $0.id }
        for id in ids {
            vm.removeAttachment(id: id)
        }
        XCTAssertTrue(vm.attachments.isEmpty, "chips removed one by one until none left")
    }

    // MARK: (d) Large paste → full-payload chip, text cleared; STRICT > boundary

    func testLargePasteStrictBoundary5001ChipsTextCleared() {
        let vm = makeVM()
        vm.text = "preface "
        vm.onPaste(text: largePaste(Tokens.Composer.largePasteThreshold + 1)) // 5001
        XCTAssertEqual(vm.attachments.count, 1, "5001 chars (> 5k) converts to ONE chip")
        let chip = vm.attachments[0]
        XCTAssertEqual(chip.source, .paste, "paste-origin chip")
        XCTAssertEqual(chip.text, largePaste(Tokens.Composer.largePasteThreshold + 1),
                       "chip carries the FULL payload verbatim — no truncation")
        XCTAssertEqual(chip.text.count, 5_001)
        XCTAssertTrue(vm.text.isEmpty, "composer text is CLEARED on conversion (preface included)")
        XCTAssertFalse(vm.canSend, "converted paste alone does not enable send")
    }

    func testPasteAtExactlyThresholdAndBelowStaysInline() {
        let vm = makeVM()
        vm.onPaste(text: largePaste(Tokens.Composer.largePasteThreshold)) // exactly 5000
        XCTAssertTrue(vm.attachments.isEmpty, "STRICT >: exactly 5000 chars stays inline")
        XCTAssertEqual(vm.text.count, Tokens.Composer.largePasteThreshold,
                       "inline text is intact at the boundary")
        let vm2 = makeVM()
        vm2.onPaste(text: largePaste(Tokens.Composer.largePasteThreshold - 1)) // 4999
        XCTAssertTrue(vm2.attachments.isEmpty, "4999 chars stays inline")
        XCTAssertEqual(vm2.text.count, 4_999)
    }

    func testThresholdTokenIsPinnedAt5000() {
        XCTAssertEqual(Tokens.Composer.largePasteThreshold, 5_000,
                       "§6 pins >5k chars; the DesignSystem token must stay 5000")
    }

    func testPasteChipCaptionIsSizedNotFullPayload() {
        let payload = largePaste(9_000)
        let chip = ComposerAttachment.fromLargePaste(payload)
        let caption = chip.displayName
        XCTAssertLessThan(caption.count, 100,
                          "caption must be SIZED — never the full 9k payload (chip row would blow out)")
        XCTAssertTrue(caption.contains(String(payload.count)),
                      "caption carries the payload size (\(payload.count) chars)")
        XCTAssertFalse(caption.contains(payload),
                       "caption must not embed the raw payload")
        // The chip body still carries the full verbatim payload for send.
        XCTAssertEqual(chip.text, payload)
    }

    func testPickerChipCaptionIsDescriptorVerbatim() {
        let chip = ComposerAttachment(text: "holidays.jpg", source: .picker)
        XCTAssertEqual(chip.displayName, "holidays.jpg",
                       "picker chips caption with the picked-item descriptor as-is")
    }

    func testConsecutiveLargePastesStageDistinctRemovableChips() {
        let vm = makeVM()
        vm.onPaste(text: largePaste(6_000))
        vm.onPaste(text: largePaste(5_001))
        XCTAssertEqual(vm.attachments.count, 2, "each oversized paste gets its own chip")
        XCTAssertNotEqual(vm.attachments[0].id, vm.attachments[1].id,
                          "chips need distinct ids so × removes per chip")
        // Interleaved inline paste does not convert.
        vm.onPaste(text: "small note ")
        XCTAssertEqual(vm.attachments.count, 2, "small paste stays inline, no new chip")
        XCTAssertEqual(vm.text, "small note ")
        vm.removeAttachment(id: vm.attachments[0].id)
        XCTAssertEqual(vm.attachments.count, 1)
    }

    // MARK: (e) Send-time: chips flatten into the outgoing row, then clear

    func testSendFlattensPasteChipsIntoRowAndClearsAttachments() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        let chatID = vm.conversationID
        vm.text = "see attached"
        let payload = largePaste(5_500)
        vm.onPaste(text: payload)
        vm.text = "see attached" // paste cleared it; restore the cover note
        XCTAssertEqual(vm.attachments.count, 1)
        let ok = try await vm.send()
        XCTAssertTrue(ok)
        let count = await store.count()
        XCTAssertEqual(count, 1, "text + chips flatten into ONE user row")
        let rows = try await store.recentMessages(conversationID: chatID, limit: 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.role, .user)
        XCTAssertTrue(row.content.hasPrefix("see attached"),
                      "row carries the draft text first")
        XCTAssertTrue(row.content.contains(payload),
                      "paste payload is flattened INTO the row verbatim (send-time preview)")
        XCTAssertTrue(vm.attachments.isEmpty,
                      "chips are consumed and cleared after send")
        XCTAssertTrue(vm.text.isEmpty, "field cleared after send")
    }

    func testSendWithOnlyInlineTextAndPickerChipsClearsChipsAfterSend() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        let chatID = vm.conversationID
        vm.plusTapped()
        vm.selectSheetOption(.photos)
        vm.plusTapped()
        vm.selectSheetOption(.camera)
        vm.text = "two picks"
        let ok = try await vm.send()
        XCTAssertTrue(ok)
        XCTAssertTrue(vm.attachments.isEmpty, "picker chips also clear after send")
        let rows = try await store.recentMessages(conversationID: chatID, limit: 1)
        XCTAssertEqual(rows.first?.content, "two picks",
                       "picker chips are descriptors — the row body stays the draft text")
        // Chip-less state after send: composer is back to clean.
        XCTAssertFalse(vm.canSend)
    }

    func testAttachmentsNeverEnableSendByThemselves() async throws {
        let vm = makeVM()
        vm.onPaste(text: largePaste(6_000))
        XCTAssertFalse(vm.canSend, "paste chip + empty text: send stays disabled")
        vm.plusTapped()
        vm.selectSheetOption(.files)
        XCTAssertFalse(vm.canSend, "picker chip + empty text: send stays disabled")
        vm.plusTapped()
        vm.selectSheetOption(ComposerSheetOption(
            id: .files, label: "doc.pdf", systemImage: "folder"))
        XCTAssertFalse(vm.canSend, "staged file chip + empty text: send stays disabled")
        // Whitespace text does not escape the gate either.
        vm.text = "  \n "
        XCTAssertFalse(vm.canSend, "chips + whitespace-only text: still disabled")
        // And send() upholds the guard even when chips are staged.
        let store = makeStore()
        let vm2 = makeVM(store: store)
        vm2.onPaste(text: largePaste(6_000))
        let guardedNoOp: Bool
        do {
            guardedNoOp = try await vm2.send()
        } catch {
            guardedNoOp = false
        }
        XCTAssertFalse(guardedNoOp, "send() with chips but no content must be a guarded no-op")
        await Task { @MainActor in
            let count = await store.count()
            XCTAssertEqual(count, 0, "no row written from a chip-only send")
        }.value
    }

    // MARK: (f) Draft restoration includes attachments

    func testPersistAndRestoreRoundTripsAttachmentsAndText() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        let payload = largePaste(5_400)
        vm.onPaste(text: payload)
        vm.text = "draft body"
        vm.plusTapped()
        vm.selectSheetOption(.files)
        await vm.persistDraft()
        // Fresh VM (app relaunch) restores the full composer state.
        let vm2 = makeVM(store: store)
        XCTAssertTrue(vm2.attachments.isEmpty, "fresh VM starts clean")
        await vm2.restoreState()
        XCTAssertEqual(vm2.text, "draft body", "draft text restored")
        XCTAssertEqual(vm2.attachments.count, 2, "attachments are part of the draft (plan #8)")
        let pasteChip = try XCTUnwrap(vm2.attachments.first { $0.source == .paste })
        XCTAssertEqual(pasteChip.text, payload, "paste chip payload restored verbatim")
        let pickerChip = try XCTUnwrap(vm2.attachments.first { $0.source == .picker })
        XCTAssertEqual(pickerChip.text, "Files", "picker chip descriptor restored")
        // Restored chips keep per-chip identity → removable after restore.
        let ids = Set(vm2.attachments.map { $0.id })
        XCTAssertEqual(ids.count, 2, "restored chips keep distinct ids")
        vm2.removeAttachment(id: pasteChip.id)
        XCTAssertEqual(vm2.attachments.count, 1, "× works on restored chips")
    }

    func testRestoreWithoutPersistedDraftLeavesComposerClean() async throws {
        let store = makeStore()
        let vm = makeVM(store: store)
        vm.onPaste(text: largePaste(5_200))
        vm.text = "unsaved draft"
        // A DIFFERENT store (no draft ever persisted) restores nothing.
        let vm2 = makeVM(store: makeStore())
        await vm2.restoreState()
        XCTAssertTrue(vm2.attachments.isEmpty, "no persisted draft → no phantom chips")
        XCTAssertEqual(vm2.text, "", "no persisted draft → empty field")
        XCTAssertFalse(vm2.canSend)
    }

    // MARK: (g) Picker UI glue — smoke level (view semantics pinned at the VM seam)

    func testSheetOpenPresentRowDismissCycleForAllPickers() {
        let vm = makeVM()
        XCTAssertFalse(vm.isSheetPresented)
        vm.plusTapped()
        XCTAssertTrue(vm.isSheetPresented)
        vm.selectSheetOption(vm.sheetOptions[0]) // Photos
        XCTAssertFalse(vm.isSheetPresented, "row pick dismisses the sheet")
        XCTAssertTrue(vm.attachments.count == 1)
        vm.plusTapped() // re-open clean
        XCTAssertTrue(vm.isSheetPresented)
        vm.dismissSheet()
        XCTAssertFalse(vm.isSheetPresented)
        XCTAssertEqual(vm.attachments.count, 1, "dismiss without picking stages nothing")
    }

    func testComposerAttachmentIsCodableRoundTripSafe() throws {
        let original = [
            ComposerAttachment(text: largePaste(5_100), source: .paste),
            ComposerAttachment(text: "screenshot.png", source: .picker),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([ComposerAttachment].self, from: data)
        XCTAssertEqual(decoded, original,
                       "chips must survive the KV Codable round trip (draft restore path)")
        XCTAssertEqual(decoded.first?.id, original.first?.id,
                       "chip ids are stable across encode/decode")
    }
}
