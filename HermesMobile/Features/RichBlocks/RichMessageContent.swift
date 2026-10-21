import SwiftUI

/// Where an assistant reply carries `jarvis-rich` blocks (requirement 5): the reply's markdown is
/// split around each fenced ```jarvis-rich block, which renders natively (polls, charts with a
/// data table, forms, buttons, checklists, tables, cards…) while the text around it renders as
/// usual. A fence that doesn't parse stays visible as text, so nothing is ever lost.
enum RichMessageSegments {
    enum Part: Equatable {
        case text(String)
        case rich([RichBlock], raw: String)
        /// A home-screen widget JARVIS designed (requirement 8), from a ```jarvis-widget fence.
        case widget(JarvisWidgetSpec, raw: String)

        static func == (lhs: Part, rhs: Part) -> Bool {
            switch (lhs, rhs) {
            case let (.text(a), .text(b)): return a == b
            case let (.rich(_, a), .rich(_, b)): return a == b
            case let (.widget(_, a), .widget(_, b)): return a == b
            default: return false
            }
        }
    }

    static let opening = "```" + RichContentPayload.fenceMarker
    static let widgetOpening = "```" + JarvisWidgetSpec.fenceMarker

    /// The reply's parts, or nil when it has no parseable rich or widget block (the usual case).
    static func split(_ content: String) -> [Part]? {
        guard content.contains(opening) || content.contains(widgetOpening) else { return nil }
        var parts: [Part] = []
        var rest = Substring(content)
        var foundRich = false
        while let start = nextFence(in: rest) {
            let before = String(rest[..<start.range.lowerBound])
            let afterOpening = rest[start.range.upperBound...]
            // The fence closes at the next line that is exactly ```.
            guard let bodyStart = afterOpening.firstIndex(of: "\n"),
                  let close = afterOpening[bodyStart...].range(of: "\n```") else { break }
            let fenced = String(rest[start.range.lowerBound..<close.upperBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(before)) }
            if start.isWidget, let spec = JarvisWidgetSpec.parse(fenced) {
                parts.append(.widget(spec, raw: fenced))
                foundRich = true
            } else if !start.isWidget, let blocks = RichContentPayload.parse(fenced) {
                parts.append(.rich(blocks, raw: fenced))
                foundRich = true
            } else {
                parts.append(.text(fenced))
            }
            rest = rest[close.upperBound...]
        }
        let tail = String(rest)
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(tail)) }
        return foundRich ? parts : nil
    }

    /// The first rich or widget fence in `text`.
    private static func nextFence(in text: Substring) -> (range: Range<Substring.Index>, isWidget: Bool)? {
        let rich = text.range(of: opening)
        let widget = text.range(of: widgetOpening)
        switch (rich, widget) {
        case let (rich?, widget?): return rich.lowerBound <= widget.lowerBound ? (rich, false) : (widget, true)
        case let (rich?, nil): return (rich, false)
        case let (nil, widget?): return (widget, true)
        default: return nil
        }
    }
}

/// Sends a rich block's reply (a button, a poll vote, a form) as the user's next message.
struct RichReplyAction {
    var send: (String) -> Void = { _ in }
    func callAsFunction(_ text: String) { send(text) }
}

private struct RichReplyKey: EnvironmentKey {
    static let defaultValue: RichReplyAction? = nil
}

extension EnvironmentValues {
    var richReply: RichReplyAction? {
        get { self[RichReplyKey.self] }
        set { self[RichReplyKey.self] = newValue }
    }
}

extension RichInteractionStore {
    /// Poll picks, checklist ticks and form drafts, per message and block, for this launch.
    @MainActor static let shared = RichInteractionStore()
}

/// An assistant reply with rich blocks.
struct RichMessageContent: View {
    let parts: [RichMessageSegments.Part]
    let messageID: String
    @Environment(\.richReply) private var richReply

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text):
                    MarkdownRenderer(content: text)
                case .rich(let blocks, _):
                    RichBlocksView(blocks: blocks, messageID: messageID, interactions: RichInteractionStore.shared,
                                   onSend: richReply.map { reply in { reply($0) } })
                case .widget(let spec, _):
                    JarvisWidgetPreviewCard(spec: spec)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.message")
    }
}
