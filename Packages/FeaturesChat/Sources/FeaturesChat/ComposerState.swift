import Foundation
import DesignSystem

// MARK: - Item 4: Composer (feature #3, P0) — pure logic, UI Law §6, verbatim:
//   • Rounded capsule docked above keyboard; ＋ (left), text field,
//     mic + waveform (right). ＋ opens bottom sheet: Photos, Camera, Files
//     (+ Hermes workspace files) — exactly those rows, in that order.
//   • Tool toggles appear as blue labeled chips with × to clear — tools are
//     opt-in chips, never silent.
//   • Composer grows to ~5 lines (ComposerViewModel.maxLines, inside the
//     5–6-line §6 window) then scrolls internally; send enables only with
//     non-whitespace content; long-press send = one-off model chooser;
//     large pastes (> Tokens.Composer.largePasteThreshold) auto-convert to
//     attachment chips.
//   • Model context picker at top of conversation, never in the composer —
//     the composer only ever surfaces the one-off chooser intent.
//
// Pure logic: no UIKit/SwiftUI. Deterministic time via the injected clock
// (tester contract) so send rows are reproducible in tests.

/// One removable attachment chip. Attachments land as chips whether they came
/// from the ＋ sheet pickers (`.picker`) or from an oversized paste
/// (`.paste`) — the composer never grows to fit a paste (UI Law §6).
public struct ComposerAttachment: Identifiable, Sendable, Equatable, Codable {
    public enum Source: String, Sendable, Equatable, Codable {
        /// Text captured from an oversized paste (content kept verbatim).
        case paste
        /// Anything picked via the ＋ sheet (real pickers are Item 6).
        case picker
    }

    public let id: UUID
    /// Full pasted payload (paste origin) or picked-item descriptor.
    public let text: String
    public let source: Source

    public init(id: UUID = UUID(), text: String, source: Source) {
        self.id = id
        self.text = text
        self.source = source
    }

    /// Chip caption: paste chips show a sized payload summary (never the
    /// full 5k+ payload — the chip row would blow out); picker chips show
    /// the picked-item descriptor verbatim.
    public var displayName: String {
        switch source {
        case .paste:
            return "Pasted text · \(text.count) chars"
        case .picker:
            return text
        }
    }

    /// Large paste → chip factory (UI Law §6). The chip carries the FULL
    /// pasted payload verbatim — never a truncation.
    public static func fromLargePaste(_ text: String) -> ComposerAttachment {
        ComposerAttachment(text: text, source: .paste)
    }
}

// MARK: - Model/tool chips (opt-in, labeled, never silent)

/// A model/tool the user has explicitly opted into for the next message.
/// Opting in ALWAYS surfaces a labeled chip — silent tool state is forbidden
/// (UI Law §6: "tools are opt-in chips, never silent").
public struct ComposerModelOption: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    /// Catalog the ＋ sheet toggles on. Non-empty labels (§6: chips are
    /// labeled, never icon-silent); single-model ids are unique — toggling
    /// an id never resolves to a different model.
    public static let defaults: [ComposerModelOption] = [
        ComposerModelOption(id: "webSearch", label: "Web search"),
        ComposerModelOption(id: "canvas", label: "Canvas"),
        ComposerModelOption(id: "agentRun", label: "Agent run"),
        ComposerModelOption(id: "memory", label: "Memory"),
    ]
}

// MARK: - ＋ sheet rows (bottom sheet per UI Law §6)

/// One row of the ＋ bottom sheet. Real Photos/Camera/Files pickers are
/// Item 6 — the row set/order is the contract this item ships.
public struct ComposerSheetOption: Identifiable, Sendable, Equatable {
    public enum ID: String, Sendable, Equatable, Codable {
        case photos, camera, files, hermesFiles
    }

    public let id: ID
    public let label: String
    public let systemImage: String

    public init(id: ID, label: String, systemImage: String) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
    }

    /// Fixed row set, fixed display order: Photos, Camera, Files, Hermes
    /// workspace files (UI Law §6 — exactly these four, no extras).
    public static let standard: [ComposerSheetOption] = [
        ComposerSheetOption(id: .photos, label: "Photos", systemImage: "photo"),
        ComposerSheetOption(id: .camera, label: "Camera", systemImage: "camera"),
        ComposerSheetOption(id: .files, label: "Files", systemImage: "folder"),
        ComposerSheetOption(id: .hermesFiles, label: "Hermes files", systemImage: "externaldrive.connected.to.line.below"),
    ]
}

// MARK: - Intents (tester contract: event sink)

/// Composer intents surfaced to the app target. The pure machine never
/// performs side effects — it emits these and the view/apptarget acts.
public enum ComposerEvent: Sendable, Equatable {
    /// Long-press send: present the one-off model chooser (§6).
    case showModelChooser
    /// Waveform button: START A CALL (UI Law §7) — never a dictation mode.
    case startCall
}
