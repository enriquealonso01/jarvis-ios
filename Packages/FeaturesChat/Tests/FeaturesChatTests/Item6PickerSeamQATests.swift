import XCTest
import Persistence
import DesignSystem
@testable import FeaturesChat

/// Item 6 TESTER QA — real-picker seam (feature #8, plan §4 #8 / UI Law §6).
/// The prior Item6ComposerAttachmentQATests pinned the placeholder
/// `selectSheetOption` staging contract; NOTHING covered the seam the real
/// PhotosPicker / camera capture / fileImporter / Hermes-file glue actually
/// drives: `ComposerViewModel.record(PickedItem)` + `ComposerAttachments`
/// (dedupe, size budgets, descriptor kinds, localPath → send-time payloads).
/// Four targeted tests, pure logic only, same fake pattern as the main suite.
@MainActor
final class Item6PickerSeamQATests: XCTestCase {

    private var sink: [ComposerEvent] = []

    private func makeVM(store: PersistenceStore? = nil) -> ComposerViewModel {
        ComposerViewModel(
            store: store ?? PersistenceStore(),
            models: ComposerModelOption.defaults,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            events: { [weak self] in self?.sink.append($0) }
        )
    }

    // MARK: 1 — record(): staging, dedupe, budget rejection (never silent)

    func testRecordStagesDeduplicatesAndSurfacesRejections() throws {
        let vm = makeVM()
        // Camera capture: file-backed image item stages exactly one chip.
        let capture = ComposerAttachments.PickedItem(
            name: "IMG_0001.HEIC", byteSize: 2_400_000,
            localPath: "/tmp/jarvis/IMG_0001.HEIC")
        let first = vm.record(capture)
        guard case .staged(let chip) = first else {
            return XCTFail("camera capture must stage: got \(first)")
        }
        XCTAssertEqual(chip.source, .picker)
        XCTAssertEqual(chip.text, "IMG_0001.HEIC", "chip caption = picked descriptor")
        XCTAssertEqual(vm.attachments.count, 1)

        // Re-picking the SAME descriptor dedupes to the existing chip id —
        // never a second identical chip (ChatGPT re-pick grammar).
        let repick = vm.record(ComposerAttachments.PickedItem(
            name: "IMG_0001.HEIC", byteSize: 2_400_500))
        XCTAssertEqual(repick, .duplicate(existingID: chip.id),
                       "same-descriptor re-pick → duplicate(existingID), not a stacked chip")
        XCTAssertEqual(vm.attachments.count, 1, "dedupe never stacks")

        // Over-budget pick is REJECTED and surfaced — never silently dropped.
        let tooBig = vm.record(ComposerAttachments.PickedItem(
            name: "movie.mov", byteSize: ComposerAttachments.maxAttachmentBytes + 1))
        XCTAssertEqual(
            tooBig,
            .rejected(.tooLarge(limitBytes: ComposerAttachments.maxAttachmentBytes)))
        XCTAssertEqual(vm.lastRejection, .tooLarge(limitBytes: ComposerAttachments.maxAttachmentBytes),
                       "rejection is surfaced on the VM for the view to present")
        XCTAssertEqual(vm.attachments.count, 1, "rejected pick stages nothing")
        vm.clearRejection()
        XCTAssertNil(vm.lastRejection, "view clears the surfaced rejection after presenting")
    }

    // MARK: 2 — camera vs Hermes-workspace descriptor shapes on ONE message

    func testCameraAndHermesFilesSendDistinctPayloadShapes() async throws {
        let store = PersistenceStore()
        let vm = makeVM(store: store)
        let chatID = vm.conversationID
        // Camera capture: file-backed image (localPath + .heic → kind image).
        vm.record(ComposerAttachments.PickedItem(
            name: "IMG_0042.HEIC", byteSize: 3_100_000,
            localPath: "/tmp/jarvis/IMG_0042.HEIC"))
        // Hermes workspace file: descriptor-only (size 0, no local path) —
        // validate() lets size-0 descriptor-only items through.
        vm.record(ComposerAttachments.PickedItem(
            name: "weekly-notes.md", byteSize: 0, localPath: nil))
        XCTAssertEqual(vm.attachments.count, 2, "camera + hermes chips both staged")
        vm.text = "capture + notes"
        let ok = try await vm.send()
        XCTAssertTrue(ok)
        let rows = try await store.recentMessages(conversationID: chatID, limit: 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.attachments.count, 2, "both picks persist as descriptors")
        let camera = try XCTUnwrap(
            row.attachments.first { $0.name == "IMG_0042.HEIC" },
            "camera capture descriptor present")
        XCTAssertEqual(camera.kind, "image", ".HEIC capture maps to kind image")
        XCTAssertEqual(camera.localPath, "/tmp/jarvis/IMG_0042.HEIC",
                       "send-time preview carries the capture's local path")
        let hermes = try XCTUnwrap(
            row.attachments.first { $0.name == "weekly-notes.md" },
            "hermes workspace descriptor present")
        XCTAssertEqual(hermes.kind, "file", "non-image workspace file maps to kind file")
        XCTAssertNil(hermes.localPath, "descriptor-only hermes file has no local path")
        XCTAssertTrue(vm.attachments.isEmpty, "chips consumed after send")
    }

    // MARK: 3 — mixed paste + picker chips flatten onto ONE message

    func testMixedPasteAndPickerChipsFlattenToOneRowWithBothDescriptors() async throws {
        let store = PersistenceStore()
        let vm = makeVM(store: store)
        let chatID = vm.conversationID
        let payload = String(repeating: "log line\n", count: 600) // 5400 chars > 5k
        vm.onPaste(text: payload)                                  // paste chip
        vm.record(ComposerAttachments.PickedItem(
            name: "holidays.jpg", byteSize: 1_800_000,
            localPath: "/tmp/jarvis/holidays.jpg"))                // picker chip
        XCTAssertEqual(vm.attachments.count, 2, "one paste chip + one picker chip")
        vm.text = "trip notes"
        let ok = try await vm.send()
        XCTAssertTrue(ok)
        let rows = try await store.recentMessages(conversationID: chatID, limit: 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.content.hasPrefix("trip notes"), "draft text first")
        XCTAssertTrue(row.content.contains(payload), "paste payload flattened verbatim")
        XCTAssertEqual(row.attachments.count, 2,
                       "BOTH descriptors land on the row (paste AND picker)")
        XCTAssertTrue(row.attachments.contains { $0.kind == "paste" },
                      "paste chip declares its descriptor")
        let photo = try XCTUnwrap(row.attachments.first { $0.kind == "image" })
        XCTAssertEqual(photo.name, "holidays.jpg")
        XCTAssertTrue(vm.attachments.isEmpty && vm.text.isEmpty, "clean after send")
    }

    // MARK: 4 — mixed-source draft restore → send still writes correct kinds

    func testMixedSourceDraftRestoresAndSendsWithCorrectKinds() async throws {
        let store = PersistenceStore()
        let vm = makeVM(store: store)
        let chatID = vm.conversationID
        vm.onPaste(text: String(repeating: "y", count: 5_200))     // paste chip
        vm.record(ComposerAttachments.PickedItem(
            name: "contract.pdf", byteSize: 420_000,
            localPath: "/tmp/jarvis/contract.pdf"))                // picker chip
        await vm.persistDraft()

        // Relaunch: fresh VM restores BOTH sources from the KV draft.
        let vm2 = makeVM(store: store)
        await vm2.restoreState()
        XCTAssertEqual(vm2.attachments.count, 2, "mixed-source draft restores both chips")
        XCTAssertTrue(vm2.attachments.contains { $0.source == .paste })
        XCTAssertTrue(vm2.attachments.contains { $0.source == .picker })

        // Send after restore: picked-item metadata (paths) did NOT survive
        // the KV round trip, but extension-based kind mapping still holds.
        vm2.text = "resumed draft"
        let ok = try await vm2.send()
        XCTAssertTrue(ok)
        let rows = try await store.recentMessages(conversationID: chatID, limit: 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.attachments.count, 2)
        XCTAssertTrue(row.attachments.contains { $0.kind == "paste" })
        XCTAssertEqual(row.attachments.first { $0.kind == "file" }?.name, "contract.pdf",
                       "pdf picker chip keeps kind file across draft restore")
        XCTAssertTrue(row.content.contains("resumed draft"))
        XCTAssertTrue(row.content.contains(String(repeating: "y", count: 5_200)),
                      "restored paste payload still flattens verbatim")
    }
}
