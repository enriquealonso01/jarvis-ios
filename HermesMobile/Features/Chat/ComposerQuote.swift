import Foundation

/// A passage the user explicitly selected from a completed response.
///
/// Quotes stay separate from typed text so pasted Markdown never turns into a
/// chip. The stable id also lets identical passages remain distinct and be
/// removed one at a time.
struct ComposerQuote: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    /// The user's comment on the selected passage ("Reply to JARVIS"). Nil for
    /// passages quoted without a comment.
    let comment: String?

    init(id: UUID = UUID(), text: String, comment: String? = nil) {
        self.id = id
        self.text = text
        self.comment = comment
    }

    /// A single-line label for the chip. The full passage remains in `text`.
    var preview: String {
        let source = (comment?.isEmpty == false ? comment : text) ?? text
        let collapsed = source
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > 72 else { return collapsed }
        return String(collapsed.prefix(71)) + "…"
    }
}

/// The user-editable parts of one persisted composer draft.
struct ComposerDraftContent: Equatable, Sendable {
    var text: String
    var quotes: [ComposerQuote]

    static let empty = ComposerDraftContent(text: "", quotes: [])

    var isEmpty: Bool {
        text.isEmpty && quotes.isEmpty
    }
}

/// Converts explicit quote metadata into the ordinary Markdown text understood
/// by the existing chat endpoints.
enum ComposerQuoteMessageFormatter {
    static func message(text: String, quotes: [ComposerQuote]) -> String {
        let quotedPassages = quotes.map { quote in
            let passage = quote.text
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            guard let comment = quote.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !comment.isEmpty
            else { return passage }
            return passage + "\n\n" + comment
        }

        return (quotedPassages + (text.isEmpty ? [] : [text]))
            .joined(separator: "\n\n")
    }
}
