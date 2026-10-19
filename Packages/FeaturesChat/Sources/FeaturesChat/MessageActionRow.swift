import Foundation
import SwiftUI
import Persistence
import DesignSystem

// MARK: - Item 9: Message action row (UI-Expansion §A, UI Law §3)
//
// UI Law §3, verbatim: "Completed responses get an action row: copy, thumbs,
// read-aloud, share, ••• (regenerate with model/effort choices)." The Item-9
// scope is the row on completed assistant/user message rows with
// copy / regenerate / share / •••; read-aloud (feature #45) stays Item 12
// (voice stack), thumbs folded into ••• later.
//
// Law of the row (cross-cutting ADOPT): every control is FUNCTIONAL —
// no fake buttons, no inactive affordances. A control whose handler does
// not exist in this item (••• entries) or whose capability is missing
// (regenerate with no send path) is NOT RENDERED, never shown disabled.
//
// Pure decision logic lives in `MessageActionRowEngine` (headless-testable,
// macOS-lane safe); `MessageActionRowView` renders it. Both compose the
// Item-8 `TranscriptLayoutEngine` (Task 1 merge) — transcript order shifts
// the row's windowed position without any Item-9-specific code.

/// What one action does when the user taps it.
public enum MessageAction: String, Sendable, Equatable, CaseIterable {
    case copy
    case regenerate
    case share
    case more
}

/// Why the row decides the way it does (unit-test contract surface).
public enum MessageActionContext: Sendable, Equatable {
    /// Completed = terminal: sent (includes stopped — §3 stop freezes
    /// partials), failed rows keep their text and get a functional row too.
    case completed
    /// Not terminal: streaming / sending rows get NO row (§3 — a row on a
    /// moving tail would act on half-written text; the row appears when the
    /// message completes).
    case inFlight
}

/// Everything the engine needs to decide the row: the Item-8 transcript row
/// facts plus the capabilities this surface actually has.
public struct MessageActionRowInput: Sendable, Equatable {
    public let isUser: Bool
    public let status: MessageStatus
    /// True when this row is the newest row of the transcript.
    public let isLastRow: Bool
    /// Capability: a real regenerate send path exists (live transport or
    /// outbox). False in headless transcripts — the control is OMITTED.
    public let canRegenerate: Bool
    /// Capability: functional ••• entries exist (Item 12 wires these).
    public let hasMoreEntries: Bool

    public init(isUser: Bool, status: MessageStatus, isLastRow: Bool,
                canRegenerate: Bool = false, hasMoreEntries: Bool = false) {
        self.isUser = isUser
        self.status = status
        self.isLastRow = isLastRow
        self.canRegenerate = canRegenerate
        self.hasMoreEntries = hasMoreEntries
    }
}

/// One resolved control the view renders (or doesn't).
public struct ResolvedMessageAction: Sendable, Equatable, Identifiable {
    public let action: MessageAction
    public let enabled: Bool
    public let systemImage: String
    public let label: String

    public var id: String { action.rawValue }

    public init(action: MessageAction, enabled: Bool, systemImage: String, label: String) {
        self.action = action
        self.enabled = enabled
        self.systemImage = systemImage
        self.label = label
    }
}

/// Pure row-resolution logic. No SwiftUI, no I/O — pinned headlessly by
/// Item9MessageActionsQATests (macOS lane).
public enum MessageActionRowEngine: Sendable {

    /// Does this transcript row show an action row at all? Only COMPLETED
    /// rows do (streaming/sending tails get none; failed rows keep theirs —
    /// the text survived and copy/share still work).
    public static func showsRow(isStreaming: Bool, status: MessageStatus) -> Bool {
        if isStreaming { return false }
        return status == .sent || status == .failed
    }

    /// Context classification for a stored/live row.
    public static func context(for status: MessageStatus) -> MessageActionContext {
        switch status {
        case .sending, .streaming: return .inFlight
        case .sent, .failed: return .completed
        }
    }

    /// Resolve the visible controls for one message row, in §3 order:
    /// copy → regenerate → share → •••.
    ///
    /// - copy: always present, always functional (terminal text is real).
    /// - regenerate: ONLY the last assistant row, ONLY when a real send
    ///   path exists (`canRegenerate`). Regenerating an older turn would
    ///   rewrite history mid-conversation, and a regenerate without a send
    ///   path would be a fake button — both are OMITTED, not disabled.
    /// - share: always present (share sheet with the message text).
    /// - more: ••• menu. Rendered ONLY when functional entries exist
    ///   (`hasMoreEntries`); Item 9 ships none, so it is omitted (Item 12
    ///   wires thumbs + read-aloud and flips this on).
    public static func actions(for input: MessageActionRowInput) -> [ResolvedMessageAction] {
        guard showsRow(isStreaming: false, status: input.status) else { return [] }

        var resolved: [ResolvedMessageAction] = [
            ResolvedMessageAction(
                action: .copy, enabled: true,
                systemImage: "doc.on.doc", label: "Copy"),
        ]

        if regenerateEligible(isUser: input.isUser, isLastRow: input.isLastRow),
           input.canRegenerate {
            resolved.append(ResolvedMessageAction(
                action: .regenerate, enabled: true,
                systemImage: "arrow.triangle.2.circlepath", label: "Regenerate"))
        }

        resolved.append(ResolvedMessageAction(
            action: .share, enabled: true,
            systemImage: "square.and.arrow.up", label: "Share"))

        if input.hasMoreEntries {
            resolved.append(ResolvedMessageAction(
                action: .more, enabled: true,
                systemImage: "ellipsis", label: "More"))
        }

        return resolved
    }

    /// Regenerate eligibility: the LAST assistant row of a completed
    /// conversation (the exchange above it is the upstream to re-run).
    /// Uniquely decidable: at most one row in a transcript qualifies.
    public static func regenerateEligible(isUser: Bool, isLastRow: Bool) -> Bool {
        !isUser && isLastRow
    }

    /// The send-payload of a regenerate: the text of the last USER message
    /// (the exchange to replay), never the assistant's own text.
    public static func regeneratePrompt(lastUserText: String?) -> String? {
        guard let lastUserText, !lastUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return lastUserText
    }

    // MARK: - Share payload

    /// What the share sheet receives for one row: JARVIS-prefixed text so
    /// the shared artifact is self-describing out of the app (ChatGPT
    /// grammar — the sheet never shares a naked blob).
    public static func shareText(for text: String, isUser: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? " " : trimmed
        return isUser ? body : "JARVIS:\n\(body)"
    }

    // MARK: - Copy

    /// The exact string UIPasteboard.general.string receives (§3 copy:
    /// the message text, no prefix, no decoration).
    public static func copyText(for text: String) -> String { text }
}

// MARK: - View model (executes the intents; effects are QA-observable)

/// Owns the action intents for one transcript. The send path for regenerate
/// is INJECTED (`performSend`) — the app wires the real transport
/// (MessageSendCoordinator: POST + outbox replay); headless tests inject a
/// recorder. With no send path the regenerate control never renders, and a
/// direct call records `.regenerateUnavailable` (never a fake success).
@MainActor
public final class MessageActionViewModel: ObservableObject {

    /// Side-effect record for QA (what actually happened on tap).
    public enum ActionEvent: Sendable, Equatable {
        case copied(text: String)
        case sharePresented(text: String)
        case regenerateStarted(promptText: String)
        case regenerateUnavailable
    }

    @Published public private(set) var lastEvent: ActionEvent?
    /// Non-nil while the share sheet should be up (the view binds a sheet).
    @Published public private(set) var shareText: String?
    /// True while a regenerate owns the send path (no double-fire).
    @Published public private(set) var isRegenerating = false

    /// The real send path (regenerate). Return value: accepted (true) —
    /// accepted means POSTed or safely outboxed, never "pretended".
    public typealias PerformSend = @Sendable (String) async -> Bool
    private let performSend: PerformSend?

    public init(performSend: PerformSend? = nil) {
        self.performSend = performSend
    }

    /// Whether this VM can actually regenerate (drives control visibility
    /// through `MessageActionRowInput.canRegenerate`).
    public var canRegenerate: Bool { performSend != nil }

    /// §3 copy: write the row's verbatim text to the pasteboard.
    public func copyTapped(text: String) {
        let payload = MessageActionRowEngine.copyText(for: text)
        writePasteboard(payload)
        lastEvent = .copied(text: payload)
    }

    /// Real pasteboard write (packages compile for macOS too — the pitfall
    /// list forbids bare UIKit symbols outside `#if canImport(UIKit)`).
    private func writePasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// §3 share: present the share sheet with the engine's share text.
    public func shareTapped(text: String, isUser: Bool) {
        let payload = MessageActionRowEngine.shareText(for: text, isUser: isUser)
        shareText = payload
        lastEvent = .sharePresented(text: payload)
    }

    /// Dismiss the share sheet (the view's sheet binding calls this).
    public func shareDismissed() {
        shareText = nil
    }

    /// §3 regenerate: replay the exchange — the last user prompt goes back
    /// through the REAL send path (transport POST, outbox when offline).
    /// Records the outcome either way; `unavailable` when there is no
    /// prompt or no send path (surfaced, never silent).
    public func regenerateTapped(promptText: String?) async {
        guard !isRegenerating else { return }
        guard let send = performSend,
              let prompt = MessageActionRowEngine.regeneratePrompt(lastUserText: promptText) else {
            lastEvent = .regenerateUnavailable
            return
        }
        isRegenerating = true
        defer { isRegenerating = false }
        let accepted = await send(prompt)
        lastEvent = accepted
            ? .regenerateStarted(promptText: prompt)
            : .regenerateUnavailable
    }
}

// MARK: - The action row view (UI Law §3)

/// One row of icon buttons under a completed message. Functional only —
/// the view renders exactly `MessageActionRowEngine.actions(for:)` output;
/// a control that would be fake never enters the list.
struct MessageActionRowView: View {
    let row: TranscriptRow
    let isLastRow: Bool
    let canRegenerate: Bool
    @ObservedObject var vm: MessageActionViewModel
    /// Pre-built regenerate intent (nil = not eligible → no control).
    var onRegenerate: (() async -> Void)? = nil

    init(row: TranscriptRow, isLastRow: Bool, canRegenerate: Bool,
         vm: MessageActionViewModel, onRegenerate: (() async -> Void)? = nil) {
        self.row = row
        self.isLastRow = isLastRow
        self.canRegenerate = canRegenerate
        self.vm = vm
        self.onRegenerate = onRegenerate
    }

    private var resolvedActions: [ResolvedMessageAction] {
        MessageActionRowEngine.actions(for: MessageActionRowInput(
            isUser: row.isUser,
            status: row.status,
            isLastRow: isLastRow,
            canRegenerate: canRegenerate,
            hasMoreEntries: false))
    }

    var body: some View {
        let actions = resolvedActions
        if !actions.isEmpty {
            HStack(spacing: 0) {
                ForEach(actions) { resolved in
                    Button {
                        run(resolved.action)
                    } label: {
                        // Quiet, tint-free tools (prototype `.tool-btn`):
                        // 15pt glyph, full 36pt hit area, accent on press.
                        Image(systemName: resolved.systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.Palette.textMuted)
                    .accessibilityLabel(resolved.label)
                    .accessibilityIdentifier("transcript.action.\(resolved.action.rawValue)")
                }
            }
            .padding(.leading, row.isUser ? 0 : -9)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcript.actionRow.\(row.id)")
        }
    }

    private func run(_ action: MessageAction) {
        switch action {
        case .copy:
            vm.copyTapped(text: row.text)
        case .share:
            vm.shareTapped(text: row.text, isUser: row.isUser)
        case .regenerate:
            Task { await onRegenerate?() }
        case .more:
            // Unreachable by construction: the engine omits ••• when no
            // functional entry exists (Item 9 ships none — Item 12 wires it).
            break
        }
    }
}
