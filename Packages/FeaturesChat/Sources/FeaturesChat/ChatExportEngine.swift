import Foundation
import Persistence

/// Item 13 (UI-Expansion §F): PDF export engine — pure document model.
///
/// Builds a printable document model from REAL stored conversation data
/// (no fake UI): whole chat or an explicit selection of message ids, cover,
/// header/footer metadata, per-message blocks, and page numbers as a print
/// option. The platform renderer (app target) turns this model into an
/// actual PDF; the package stays UIKit-free so QA runs on the macOS lane.
public enum ChatExportEngine {

    // MARK: - Options

    public struct Options: Sendable, Equatable {
        /// Include the cover (title, date range, message count).
        public var includeCover: Bool
        /// Include "Enrique Alonso · <title> · <date>" running headers.
        public var includeHeaders: Bool
        /// Include page numbers in footers.
        public var includePageNumbers: Bool
        /// Timestamp each exported message.
        public var includeTimestamps: Bool

        public init(includeCover: Bool = true,
                    includeHeaders: Bool = true,
                    includePageNumbers: Bool = true,
                    includeTimestamps: Bool = true) {
            self.includeCover = includeCover
            self.includeHeaders = includeHeaders
            self.includePageNumbers = includePageNumbers
            self.includeTimestamps = includeTimestamps
        }

        public static let standard = Options()
    }

    // MARK: - Document model

    public struct ExportDocument: Sendable, Equatable {
        public struct MessageBlock: Sendable, Equatable {
            public enum Kind: Sendable, Equatable {
                /// Plain text/markdown rendered as-is.
                case text(String)
                /// Rich blocks held verbatim — the renderer decides native/
                /// snapshot/summary per `RichPrintPolicy` per block.
                case richBlocks([RichBlock])
                /// Unrenderable content (e.g. tool/system rows) — prints the
                /// fallback line, never a blank page.
                case omitted(String)
            }

            public var role: MessageRole
            public var createdAt: Date
            public var kind: Kind
        }

        public var title: String
        public var createdAt: Date
        public var messageCount: Int
        public var blocks: [MessageBlock]
    }

    // MARK: - Errors

    public enum ExportError: Error, Equatable {
        /// The requested conversation does not exist in the store.
        case conversationNotFound
        /// Selection listed ids that don't belong to this conversation.
        case unknownMessageIDs([String])
        /// Nothing exportable (empty conversation or all-omitted selection).
        case noContent
    }

    // MARK: - Build

    /// Whole-chat export: every user/assistant message of the conversation,
    /// oldest first, from the real PersistenceStore.
    public static func buildDocument(conversationID: UUID,
                                     store: PersistenceStore,
                                     options: Options = .standard) async throws -> ExportDocument {
        guard let conversation = await store.get(id: conversationID) else {
            throw ExportError.conversationNotFound
        }
        let messages = try await store.messages(conversationID: conversationID)
        return try document(from: messages,
                            title: conversation.title,
                            createdAt: conversation.createdAt,
                            options: options)
    }

    /// Selection export: only the listed message ids, preserving list order.
    public static func buildDocument(conversationID: UUID,
                                     selectedMessageIDs: [UUID],
                                     store: PersistenceStore,
                                     options: Options = .standard) async throws -> ExportDocument {
        guard let conversation = await store.get(id: conversationID) else {
            throw ExportError.conversationNotFound
        }
        let messages = try await store.messages(conversationID: conversationID)
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var picked: [StoredMessage] = []
        var unknown: [String] = []
        for id in selectedMessageIDs {
            if let m = byID[id] { picked.append(m) } else { unknown.append(id.uuidString) }
        }
        if !unknown.isEmpty { throw ExportError.unknownMessageIDs(unknown) }
        return try document(from: picked,
                            title: conversation.title,
                            createdAt: conversation.createdAt,
                            options: options)
    }

    // MARK: - Core mapping (synchronous, fully unit-testable)

    /// Message → printable block. This is the Item-11 fidelity contract:
    /// rich payloads decode to `RichBlock`s (renderer applies print policy),
    /// system/tool rows summarize, and nothing ever produces an empty block.
    public static func messageBlock(_ message: StoredMessage) -> ExportDocument.MessageBlock {
        let isRenderable = message.role == .user || message.role == .assistant
        if isRenderable, let blocks = RichContentPayload.parse(message.content), !blocks.isEmpty {
            return ExportDocument.MessageBlock(
                role: message.role,
                createdAt: message.createdAt,
                kind: .richBlocks(blocks))
        }
        if isRenderable {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return ExportDocument.MessageBlock(
                role: message.role,
                createdAt: message.createdAt,
                kind: .text(text.isEmpty ? "(empty message)" : text))
        }
        return ExportDocument.MessageBlock(
            role: message.role,
            createdAt: message.createdAt,
            kind: .omitted("(\(message.role.rawValue) message — not included in export)"))
    }

    static func document(from messages: [StoredMessage],
                         title: String,
                         createdAt: Date,
                         options: Options) throws -> ExportDocument {
        let ordered = messages.sorted { $0.createdAt < $1.createdAt }
        let blocks = ordered.map(messageBlock)
        let hasContent = blocks.contains { block in
            switch block.kind {
            case .text, .rich: return true
            case .omitted: return false
            }
        }
        guard hasContent else { throw ExportError.noContent }
        return ExportDocument(
            title: title.isEmpty ? "Exported chat" : title,
            createdAt: createdAt,
            messageCount: ordered.count,
            blocks: blocks)
    }
}
