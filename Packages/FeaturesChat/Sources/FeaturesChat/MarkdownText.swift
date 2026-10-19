import Foundation
import SwiftUI
import DesignSystem

// MARK: - Assistant markdown (block structure + inline styles)
//
// SwiftUI's `Text(LocalizedStringKey)` only understands INLINE markdown, so a
// reply like "### Yesterday\n- **Spend:** $41.20" printed its `###` and `-`
// verbatim (seen in the QA lane). This is a small, deterministic block
// parser — headings, bullet / numbered lists, quotes, fenced code, paragraphs
// — with inline styling from Foundation's markdown parser. Pure parsing lives
// in `MarkdownBlockParser` (headless-testable); the view only draws.
//
// Streaming-safe (02 C02): an unterminated ``` fence renders as a code block
// up to the end of the partial text, so code never flickers into prose while
// tokens arrive; partial inline syntax simply renders literally until closed.

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(index: String, text: String)
    case quote(String)
    case code(language: String?, code: String)
    case rule
}

public enum MarkdownBlockParser: Sendable {

    public static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var inFence = false
        var fenceLanguage: String?
        var fenceLines: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inFence {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: fenceLanguage, code: fenceLines.joined(separator: "\n")))
                    inFence = false
                    fenceLanguage = nil
                    fenceLines.removeAll()
                } else {
                    fenceLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                inFence = true
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                fenceLanguage = lang.isEmpty ? nil : lang
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: heading, text: text))
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let item = bulletText(trimmed) {
                flushParagraph()
                blocks.append(.bullet(item))
                continue
            }

            if let item = numberedItem(trimmed) {
                flushParagraph()
                blocks.append(.numbered(index: item.0, text: item.1))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if case .quote(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + text)
                } else {
                    blocks.append(.quote(text))
                }
                continue
            }

            paragraph.append(trimmed)
        }

        if inFence {
            // Streaming: the fence is still open — keep it a code block.
            blocks.append(.code(language: fenceLanguage, code: fenceLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }

    /// True when the text needs the block renderer (cheap pre-check so plain
    /// one-paragraph replies stay a single Text).
    public static func hasBlockSyntax(_ source: String) -> Bool {
        let blocks = parse(source)
        if blocks.count > 1 { return true }
        if case .paragraph? = blocks.first { return false }
        return !blocks.isEmpty
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return hashes
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> (String, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }

    /// Inline markdown (bold, italic, code, links) → AttributedString; a
    /// parse failure degrades to the literal text (never blank).
    public static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

/// Draws parsed markdown blocks in the Orbital Core reading style:
/// full-width, body type, generous line spacing, no bubble.
public struct MarkdownText: View {
    public let source: String
    public var font: Font = Tokens.Typography.body
    public var color: Color = Tokens.Palette.textBody

    public init(_ source: String,
                font: Font = Tokens.Typography.body,
                color: Color = Tokens.Palette.textBody) {
        self.source = source
        self.font = font
        self.color = color
    }

    public var body: some View {
        let blocks = MarkdownBlockParser.parse(source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownBlockParser.inline(text))
                .font(headingFont(level))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(MarkdownBlockParser.inline(text))
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .bullet(let text):
            listRow(marker: "•", text: text)
        case .numbered(let index, let text):
            listRow(marker: "\(index).", text: text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Tokens.Palette.borderStrong)
                    .frame(width: 3)
                Text(MarkdownBlockParser.inline(text))
                    .font(font)
                    .italic()
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .code(let language, let code):
            MarkdownCodeBlock(language: language, code: code)
        case .rule:
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(font)
                .foregroundStyle(Tokens.Palette.textMuted)
                .frame(minWidth: 14, alignment: .trailing)
            Text(MarkdownBlockParser.inline(text))
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .callout.weight(.semibold)
        }
    }
}

/// Fenced code: language caption + horizontally scrolling monospace body.
struct MarkdownCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((language ?? "code").uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Tokens.Palette.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Palette.raised.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Tokens.Palette.textBody)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .fill(Tokens.Palette.sunken))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .strokeBorder(Tokens.Palette.border, lineWidth: 1))
    }
}
