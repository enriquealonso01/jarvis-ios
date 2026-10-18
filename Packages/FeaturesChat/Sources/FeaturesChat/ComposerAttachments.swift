import Foundation
import DesignSystem
import Persistence

// MARK: - Item 6: Attachment payload assembly (feature #8, P1 — UI Law §6)
//
// Pure-logic core behind the real Photos/Camera/Files pickers (the pickers
// themselves are thin app-target wrappers — this file has NO UIKit/SwiftUI
// so the Linux swift-test lane exercises it directly).
//
// Responsibilities:
//   • turn a picked item (photos / camera capture / file URL / Hermes
//     workspace file) into a `ComposerAttachment` chip descriptor + the
//     persisted `StoredAttachment` payload row;
//   • dedupe staged chips by descriptor (the same photo picked twice must
//     not stack two identical chips — ChatGPT grammar: a re-pick re-uses
//     the staged chip);
//   • enforce a per-attachment and total size budget BEFORE staging (a
//     rejected pick is surfaced, never silently dropped);
//   • map chips → `StoredAttachment` payloads for the send-time row write
//     (send-time previews: kind + name + local path land on the message).
//
// The app-target picker glue (V2ComposerAttachments.swift) calls
// `attachment(for:)` and hands the result to the VM; the VM staging/removal
// contract stays exactly the tester-pinned one (Item4/Item6 QA suites).

public enum ComposerAttachments {

    /// Rejection reasons — surfaced to the user, never silent.
    public enum Rejection: Equatable, Sendable {
        case tooLarge(limitBytes: Int)
        case totalTooLarge(limitBytes: Int)
        case empty
    }

    /// Per-item hard cap. Generous on purpose (photos from the picker can
    /// be several MB); the point is a bound, not a policy decision.
    public static let maxAttachmentBytes = 25_000_000
    /// Total staged budget across all chips of one draft.
    public static let maxTotalBytes = 75_000_000

    /// A picked item reduced to its pure descriptor (no UIKit types).
    public struct PickedItem: Sendable, Equatable {
        public var name: String
        public var byteSize: Int
        /// Local file path when the item is file-backed (camera capture,
        /// Files document); nil for descriptor-only items (Hermes files).
        public var localPath: String?

        public init(name: String, byteSize: Int, localPath: String? = nil) {
            self.name = name
            self.byteSize = byteSize
            self.localPath = localPath
        }
    }

    /// Outcome of staging one picked item.
    public enum Stage: Equatable, Sendable {
        /// New chip (the picked item was not already staged).
        case staged(ComposerAttachment)
        /// Same descriptor already staged — the EXISTING chip id comes
        /// back so the UI can highlight it instead of stacking a dupe.
        case duplicate(existingID: UUID)
        /// Rejected (budget/empty) — surfaced to the user.
        case rejected(Rejection)
    }

    // MARK: - Descriptor mapping (per sheet row)

    /// Map one picked item → its chip descriptor + persisted payload.
    /// `kind` follows the StoredAttachment vocabulary: image | file | paste.
    public static func attachment(for item: PickedItem, kind: String) -> ComposerAttachment {
        ComposerAttachment(text: descriptor(for: item), source: .picker)
    }

    /// The chip caption / dedupe descriptor for a picked item.
    public static func descriptor(for item: PickedItem) -> String {
        let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Attachment" : trimmed
    }

    /// The persisted `StoredAttachment` payload for a staged chip
    /// (send-time previews: this is what lands on the message row).
    public static func payload(for chip: ComposerAttachment, kind: String, localPath: String? = nil) -> StoredAttachment {
        StoredAttachment(id: chip.id, kind: kind, name: chip.text, localPath: localPath)
    }

    // MARK: - Budgets (checked BEFORE staging — rejects are surfaced)

    public static func validate(_ item: PickedItem,
                                alreadyStagedBytes: Int) -> Rejection? {
        guard item.byteSize > 0 || item.localPath == nil else {
            // File-backed items must carry a size; descriptor-only items
            // (Hermes files) are allowed through with size 0.
            return .empty
        }
        if item.byteSize > maxAttachmentBytes {
            return .tooLarge(limitBytes: maxAttachmentBytes)
        }
        if alreadyStagedBytes + item.byteSize > maxTotalBytes {
            return .totalTooLarge(limitBytes: maxTotalBytes)
        }
        return nil
    }

    // MARK: - Dedupe + staging decision (pure — no VM mutation here)

    /// Full staging decision for one picked item against the current chips.
    public static func stage(item: PickedItem,
                             kind: String,
                             staged: [ComposerAttachment]) -> Stage {
        if let rejection = validate(item, alreadyStagedBytes: stagedBytes(staged)) {
            return .rejected(rejection)
        }
        let descriptor = descriptor(for: item)
        if let existing = staged.first(where: { $0.text == descriptor && $0.source == .picker }) {
            return .duplicate(existingID: existing.id)
        }
        return .staged(ComposerAttachment(text: descriptor, source: .picker))
    }

    /// Byte budget consumed by the currently staged chips: paste chips are
    /// pure text (UTF-8 payload), picker chips count their recorded picked
    /// item size when the app target recorded one.
    public static func stagedBytes(_ staged: [ComposerAttachment],
                                   pickedItems: [UUID: PickedItem] = [:]) -> Int {
        staged.reduce(0) { total, chip in
            switch chip.source {
            case .paste:
                return total + chip.text.utf8.count
            case .picker:
                return total + (pickedItems[chip.id]?.byteSize ?? 0)
            }
        }
    }

    // MARK: - Send-time payload assembly (pure; used by the VM seam)

    /// Map staged chips → `StoredAttachment` rows for the outgoing message.
    /// Paste chips become `paste`-kind payloads (the verbatim text is
    /// flattened into the row content by the VM contract — the payload row
    /// keeps the sized caption so previews don't re-embed 5k+ chars).
    /// Picker chips map to their kind + descriptor (+ local path when the
    /// app target recorded one for the chip id).
    public static func payloads(chips: [ComposerAttachment],
                                pickedItems: [UUID: PickedItem] = [:]) -> [StoredAttachment] {
        chips.map { chip in
            switch chip.source {
            case .paste:
                return StoredAttachment(
                    id: chip.id,
                    kind: "paste",
                    name: chip.displayName,
                    localPath: nil)
            case .picker:
                let item = pickedItems[chip.id]
                return StoredAttachment(
                    id: chip.id,
                    kind: kindName(for: item),
                    name: chip.text,
                    localPath: item?.localPath)
            }
        }
    }

    /// Payload kind vocabulary from the item descriptor's extension, with a
    /// safe default. Images (photo picker, camera capture) → "image".
    public static func kindName(for item: PickedItem?) -> String {
        guard let item else { return "file" }
        let ext = fileExtension(of: item.name).lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp", "dng":
            return "image"
        case "m4a", "mp3", "wav", "aac", "caf", "aiff":
            return "audio"
        default:
            return "file"
        }
    }

    /// Extension after the last '.', trimmed; empty when absent. Pure
    /// Foundation string math (no NSString bridging → Linux-safe).
    public static func fileExtension(of name: String) -> String {
        guard let lastDot = name.lastIndex(of: "."), name.distance(from: name.startIndex, to: lastDot) > 0 else {
            return ""
        }
        let ext = name[name.index(after: lastDot)...]
        return ext.contains("/") ? "" : String(ext)
    }
}
