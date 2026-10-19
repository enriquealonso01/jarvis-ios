import SwiftUI
import DesignSystem

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Item 11: Rich Blocks — native SwiftUI renderers
//
// Renderer registry view layer. LAW: native SwiftUI only — there is no
// WKWebView, no agent HTML/JS, no DOM anywhere in this file (binding ADOPT,
// PLAN_DELTA §D). Every renderer degrades gracefully; the registry
// (`RichBlockRendererRegistry.renderPlan`) decides native-vs-fallback and
// this file draws the plan. Unknown/undecodable blocks land in
// `RichFallbackCardView` — a standard card with the block's fallbackText
// (never a crash, never a blank).
//
// Look: the UI-expansion catalog (prototype `.rich-card`) in Orbital Core
// tokens — deep-surface gradient cards with surface-border hairlines, cyan
// only on primary interactions.
//
// No-fake-button law: a control renders only when it can really do
// something. Buttons open a vetted http(s) URL, copy, or send their label to
// JARVIS through the injected `onSend` path (`RichActionRouter`); one-shot
// sends lock after firing so a double tap never sends twice.

// MARK: Entry point (one block list for one message)

/// Renders the rich blocks of one message, stacked in order. Interactive
/// state is keyed `messageID|blockID` in the shared `RichInteractionStore`
/// (per-message isolation; regenerate = new message id = fresh state).
public struct RichBlocksView: View {
    public let blocks: [RichBlock]
    public let messageID: String
    @ObservedObject public var interactions: RichInteractionStore
    /// Real handlers injected by the app surface; nil handlers remove the
    /// corresponding controls entirely (never fake).
    public var onAction: ((String, RichBlockAction) -> Void)? = nil
    public var onFormSubmit: ((String, [String: String]) -> Void)? = nil
    /// The chat's send path: buttons, poll votes and form submissions reach
    /// JARVIS as the user's next message through it.
    public var onSend: ((String) -> Void)? = nil

    public init(blocks: [RichBlock],
                messageID: String,
                interactions: RichInteractionStore,
                onAction: ((String, RichBlockAction) -> Void)? = nil,
                onFormSubmit: ((String, [String: String]) -> Void)? = nil,
                onSend: ((String) -> Void)? = nil) {
        self.blocks = blocks
        self.messageID = messageID
        self.interactions = interactions
        self.onAction = onAction
        self.onFormSubmit = onFormSubmit
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                RichBlockView(
                    block: block,
                    messageID: messageID,
                    interactions: interactions,
                    onAction: onAction,
                    onFormSubmit: onFormSubmit,
                    onSend: onSend)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.blocks.\(messageID)")
    }
}

// MARK: Registry dispatch (one block)

struct RichBlockView: View {
    let block: RichBlock
    let messageID: String
    @ObservedObject var interactions: RichInteractionStore
    var onAction: ((String, RichBlockAction) -> Void)?
    var onFormSubmit: ((String, [String: String]) -> Void)?
    var onSend: ((String) -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        switch RichBlockRendererRegistry.renderPlan(for: block) {
        case .native(let block):
            nativeBody(for: block)
        case .fallbackCard(let reason):
            RichFallbackCardView(block: block, reason: reason)
        }
    }

    @ViewBuilder
    private func nativeBody(for block: RichBlock) -> some View {
        switch block.content {
        case .text(let text):
            RichTextView(text: text, block: block)
        case .markdown(let markdown):
            RichMarkdownView(markdown: markdown, block: block)
        case .heading(let text, let level):
            RichHeadingView(text: text, level: level, block: block)
        case .code(let code, let language):
            RichCodeView(code: code, language: language, block: block)
        case .table(let headers, let rows):
            RichTableView(headers: headers, rows: rows, block: block)
        case .image(let url, let alt, let caption):
            RichImageView(url: url, alt: alt, caption: caption, block: block)
        case .buttonGroup(let buttons):
            RichButtonGroupView(
                block: block, buttons: buttons, messageID: messageID,
                interactions: interactions,
                handlerExists: buttonHandlerExists(buttons)) { action in
                    perform(action, blockID: block.id)
                }
        case .poll(let question, let options):
            RichPollView(
                block: block, question: question, options: options,
                messageID: messageID, interactions: interactions,
                onVote: onSend)
        case .chart(let kind, let title, let points):
            RichChartView(kind: kind, title: title, points: points, block: block)
        case .form(let fields, let submitLabel):
            RichFormView(
                block: block, fields: fields, submitLabel: submitLabel,
                messageID: messageID, interactions: interactions,
                submitHandlerExists: onFormSubmit != nil || onSend != nil) { draft in
                    if let onFormSubmit {
                        onFormSubmit(messageID, draft)
                    } else {
                        onSend?(RichActionRouter.formSubmissionText(
                            submitLabel: submitLabel, fields: fields, draft: draft))
                    }
                }
        case .notice(let tone, let text):
            RichNoticeView(tone: tone, text: text, block: block)
        case .citation(let title, let url):
            RichCitationView(title: title, url: url, block: block)
        case .card(let title, let subtitle, let cardBody):
            RichCardView(title: title, subtitle: subtitle, cardBody: cardBody, block: block)
        case .checklist(let items):
            RichChecklistView(
                block: block, items: items, messageID: messageID,
                interactions: interactions)
        case .fallback(let summary):
            RichFallbackCardView(
                block: block,
                reason: .decodingFailure,
                explicitSummary: summary)
        }
    }

    /// A button group renders when at least one button can really act: an
    /// external handler, the send path, or a self-contained open/copy route.
    private func buttonHandlerExists(_ buttons: [RichBlockAction]) -> Bool {
        if onAction != nil || onSend != nil { return true }
        return buttons.contains { action in
            switch RichActionRouter.route(action) {
            case .open, .copy: return true
            case .send: return false
            }
        }
    }

    private func perform(_ action: RichBlockAction, blockID: String) {
        if let onAction {
            onAction(messageID, action)
            return
        }
        switch RichActionRouter.route(action) {
        case .open(let url):
            openURL(url)
        case .copy(let text):
            RichPasteboard.write(text)
        case .send(let text):
            guard let onSend else { return }
            // One-shot: the first tap wins, a second never double-sends.
            guard interactions.markActionFired(
                messageID: messageID, blockID: blockID, actionID: action.id) else { return }
            onSend(text)
        }
    }
}

/// Real pasteboard write (packages compile for macOS too).
enum RichPasteboard {
    @MainActor
    static func write(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: Shared card pieces

/// Card title + optional supporting line (prototype `h4` + `p`).
struct RichCardHeader: View {
    let title: String?
    var subtitle: String? = nil

    var body: some View {
        if title != nil || subtitle != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Tokens.Typography.cardBody)
                        .foregroundStyle(Tokens.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Horizontal line shape (chart gridlines).
struct RichHLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Wrapping row for action buttons (no horizontal scrolling of choices).
struct RichFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = proposal.width ?? widest
        return CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: Fallback card (the never-crash, never-blank contract)

/// Standard card for unknown/undecodable/unsupported blocks. Shows the
/// block's fallbackText (guaranteed non-blank by `RichBlock` invariants).
struct RichFallbackCardView: View {
    let block: RichBlock
    let reason: RichFallbackReason
    var explicitSummary: String? = nil

    private var summaryText: String {
        explicitSummary ?? block.fallbackDisplayText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text("Unsupported content")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Tokens.Palette.textMuted)
            Text(summaryText)
                .font(Tokens.Typography.cardBody)
                .foregroundStyle(Tokens.Palette.textBody)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .jarvisCard(padding: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryText)
        .accessibilityIdentifier("rich.fallback.\(block.id)")
    }
}

// MARK: P0 renderers

struct RichTextView: View {
    let text: String
    let block: RichBlock

    var body: some View {
        Text(text)
            .font(Tokens.Typography.body)
            .foregroundStyle(Tokens.Palette.textBody)
            .lineSpacing(5)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(block.a11yLabel ?? text)
            .accessibilityIdentifier("rich.text.\(block.id)")
    }
}

/// Markdown with real block structure (headings, lists, quotes, code) plus
/// inline styles — native parsing only, never agent HTML.
struct RichMarkdownView: View {
    let markdown: String
    let block: RichBlock

    var body: some View {
        MarkdownText(markdown)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rich.markdown.\(block.id)")
    }
}

struct RichHeadingView: View {
    let text: String
    let level: Int
    let block: RichBlock

    private var font: Font {
        switch max(1, min(level, 4)) {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        case 3: return .callout.weight(.semibold)
        default: return .subheadline.weight(.semibold)
        }
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Tokens.Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(block.a11yLabel ?? text)
            .accessibilityIdentifier("rich.heading.\(block.id)")
    }
}

struct RichCodeView: View {
    let code: String
    let language: String?
    let block: RichBlock

    var body: some View {
        MarkdownCodeBlock(language: language, code: code)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(block.a11yLabel ?? "Code\(language.map { " — \($0)" } ?? "")")
            .accessibilityIdentifier("rich.code.\(block.id)")
    }
}

struct RichTableView: View {
    let headers: [String]
    let rows: [[String]]
    let block: RichBlock

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !headers.isEmpty {
                    headerRow
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(index: index, row: row)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .fill(Tokens.Palette.cardBottom))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .strokeBorder(Tokens.Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.a11yLabel ?? block.fallbackDisplayText)
        .accessibilityIdentifier("rich.table.\(block.id)")
    }

    private func tableRow(index: Int, row: [String]) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.textBody)
                    .frame(width: 120, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .overlay(alignment: .bottom) {
            if index < rows.count - 1 {
                Rectangle().fill(Tokens.Palette.border.opacity(0.7)).frame(height: 1)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: Tokens.Spacing.m) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.textSecondary)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Tokens.Palette.raised.opacity(0.55))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Palette.border).frame(height: 1)
        }
    }
}

struct RichImageView: View {
    let url: URL
    let alt: String
    let caption: String?
    let block: RichBlock

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    // Broken image → fallback semantics (never blank space).
                    placeholderView("photo.badge.exclamationmark")
                default:
                    placeholderView("photo")
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous))
            .accessibilityLabel(block.a11yLabel ?? alt)

            if let caption, RichBlocks.nonEmpty(caption) != nil {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Tokens.Palette.textMuted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.image.\(block.id)")
    }

    private func placeholderView(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Palette.elevated)
            VStack(spacing: Tokens.Spacing.s) {
                Image(systemName: systemName)
                    .font(.title2)
                    .foregroundStyle(Tokens.Palette.textMuted)
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(Tokens.Palette.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(Tokens.Spacing.l)
        }
        .frame(minHeight: 120)
    }
}

/// Buttons render ONLY when they can really act (the registry's
/// `rendersButtons(handlerExists:)` gate is the law). Approval-gated actions
/// confirm first; fired one-shot sends show a check and lock.
struct RichButtonGroupView: View {
    let block: RichBlock
    let buttons: [RichBlockAction]
    let messageID: String
    @ObservedObject var interactions: RichInteractionStore
    let handlerExists: Bool
    let fire: (RichBlockAction) -> Void

    @State private var pendingConfirmation: RichBlockAction?

    var body: some View {
        if RichBlockRendererRegistry.rendersButtons(handlerExists: handlerExists) {
            RichFlowLayout(spacing: 8) {
                ForEach(buttons) { button in
                    actionButton(button)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rich.buttonGroup.\(block.id)")
            .confirmationDialog(
                "Confirm action",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { if !$0 { pendingConfirmation = nil } }),
                titleVisibility: .visible,
                presenting: pendingConfirmation
            ) { action in
                Button(action.label) { fire(action) }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(action.confirmText ?? "JARVIS will act on “\(action.label)”.")
            }
        } else {
            // No way to act: show what the buttons were, as plain text — no
            // inert controls, and no "unsupported" alarm for a known type.
            Text(block.fallbackDisplayText)
                .font(Tokens.Typography.cardBody)
                .foregroundStyle(Tokens.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rich.buttonGroup.\(block.id)")
        }
    }

    private func actionButton(_ button: RichBlockAction) -> some View {
        let route = RichActionRouter.route(button)
        let fired = interactions.hasFired(messageID: messageID, blockID: block.id, actionID: button.id)
        return Button {
            if button.needsConfirmation {
                pendingConfirmation = button
            } else {
                fire(button)
            }
        } label: {
            HStack(spacing: 6) {
                if fired {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                } else if case .open = route {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
                Text(button.label)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(fired ? Tokens.Palette.textMuted : Tokens.Palette.accentLabel)
            .padding(.horizontal, 14)
            .frame(minHeight: Tokens.Layout.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .fill(fired ? Tokens.Palette.elevated : Tokens.Palette.accentSurface))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .strokeBorder(fired ? Tokens.Palette.border : Tokens.Palette.accentBorder,
                                  lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(fired)
        .accessibilityHint(fired ? "Sent" : "")
        .accessibilityIdentifier("rich.button.\(block.id).\(button.id)")
    }
}

/// Poll (catalog: select → Submit vote → results). Results are honest: the
/// only vote shown is the user's own — no fabricated aggregate counts.
struct RichPollView: View {
    let block: RichBlock
    let question: String
    let options: [String]
    let messageID: String
    @ObservedObject var interactions: RichInteractionStore
    /// The chat's send path; nil = the vote stays on this device.
    var onVote: ((String) -> Void)? = nil

    private var selection: Int? {
        interactions.pollSelection(messageID: messageID, blockID: block.id)
    }

    private var submitted: Bool {
        interactions.isPollSubmitted(messageID: messageID, blockID: block.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RichCardHeader(title: "Poll", subtitle: question)
            if submitted {
                results
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        pollOption(index: index, option: option)
                    }
                }
                HStack(spacing: 10) {
                    Button("Submit vote") { submit() }
                        .buttonStyle(JarvisButtonStyle(.primary))
                        .disabled(selection == nil)
                        .accessibilityIdentifier("rich.poll.\(block.id).submit")
                    Text("Your selection only")
                        .font(.caption)
                        .foregroundStyle(Tokens.Palette.textMuted)
                }
                .padding(.top, 2)
            }
        }
        .jarvisCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.a11yLabel ?? question)
        .accessibilityIdentifier("rich.poll.\(block.id)")
    }

    private func submit() {
        guard let selection, selection < options.count else { return }
        guard interactions.submitPoll(messageID: messageID, blockID: block.id) else { return }
        onVote?(RichActionRouter.pollVoteText(question: question, option: options[selection]))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(onVote == nil
                 ? "Saved on this device · no other voters or aggregated results"
                 : "Sent to JARVIS · your vote only, no aggregated results")
                .font(.caption)
                .foregroundStyle(Tokens.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let chosen = selection == index
                VStack(alignment: .leading, spacing: 6) {
                    Text(chosen ? "\(option) · Your choice" : option)
                        .font(.footnote.weight(chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? Tokens.Palette.textPrimary : Tokens.Palette.textBody)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tokens.Palette.resultTrack)
                            Capsule()
                                .fill(Tokens.Palette.chartBar)
                                .frame(width: chosen ? geo.size.width : 0)
                        }
                    }
                    .frame(height: 7)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(chosen ? "\(option), your vote" : "\(option), no votes")
                .accessibilityIdentifier("rich.poll.\(block.id).result.\(index)")
            }
        }
    }

    private func pollOption(index: Int, option: String) -> some View {
        let isSelected = selection == index
        return Button {
            interactions.selectPoll(
                messageID: messageID, blockID: block.id, optionIndex: index)
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Tokens.Palette.accent : Tokens.Palette.textMuted,
                                      lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Circle()
                            .fill(Tokens.Palette.accent)
                            .frame(width: 9, height: 9)
                    }
                }
                Text(option)
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Tokens.Layout.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Tokens.Palette.optionSelected : Tokens.Palette.option))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Tokens.Palette.borderStrong : Tokens.Palette.border,
                                  lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("rich.poll.\(block.id).option.\(index)")
    }
}

/// Chart card (catalog R06): Chart / Data table toggle, tap a bar to inspect
/// it, real values in the accessible summary — never color-only.
struct RichChartView: View {
    let kind: RichChartKind
    let title: String?
    let points: [RichChartPoint]
    let block: RichBlock

    enum ChartTab: String { case chart, table }

    @State private var tab: ChartTab = .chart
    @State private var inspected: Int?

    private let plotHeight: CGFloat = 132

    private var maxValue: Double {
        max(points.map { $0.value }.max() ?? 0, 0)
    }

    private var total: Double {
        points.map { max($0.value, 0) }.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RichCardHeader(title: title ?? "Chart", subtitle: subtitle)
            tabs
            if tab == .chart {
                chartBody
                Text(inspectedLine)
                    .font(.caption)
                    .foregroundStyle(inspected == nil ? Tokens.Palette.textMuted : Tokens.Palette.textPrimary)
                    .accessibilityIdentifier("rich.chart.\(block.id).inspect")
            } else {
                dataTable
            }
        }
        .jarvisCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(RichCharts.accessibleSummary(title: title, points: points))
        .accessibilityIdentifier("rich.chart.\(block.id)")
    }

    private var subtitle: String {
        let count = points.count
        switch kind {
        case .bar: return "\(count) values · bar chart"
        case .line: return "\(count) values · line chart"
        case .pie: return "\(count) shares of \(RichCharts.formattedValue(total))"
        }
    }

    private var inspectedLine: String {
        if let inspected, inspected < points.count {
            let point = points[inspected]
            return "\(point.label): \(RichCharts.formattedValue(point.value))"
        }
        return kind == .pie ? "Tap a row to inspect it." : "Tap a bar to inspect it."
    }

    // MARK: Segmented toggle

    private var tabs: some View {
        HStack(spacing: 0) {
            segment("Chart", .chart)
            segment("Data table", .table)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tokens.Palette.sunken))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tokens.Palette.border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.chart.\(block.id).tabs")
    }

    private func segment(_ title: String, _ value: ChartTab) -> some View {
        let isOn = tab == value
        return Button {
            tab = value
        } label: {
            Text(title)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Tokens.Palette.textPrimary : Tokens.Palette.textMuted)
                .padding(.horizontal, 12)
                .frame(minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.segment, style: .continuous)
                        .fill(isOn ? Tokens.Palette.selected : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("rich.chart.\(block.id).tab.\(value.rawValue)")
    }

    // MARK: Chart body

    @ViewBuilder
    private var chartBody: some View {
        switch kind {
        case .bar, .line:
            VStack(spacing: 6) {
                bars
                HStack(spacing: 8) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        Text(point.label)
                            .font(.caption2)
                            .foregroundStyle(Tokens.Palette.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        case .pie:
            shares
        }
    }

    private func fraction(_ value: Double) -> CGFloat {
        guard maxValue > 0 else { return 0 }
        return CGFloat(max(0, min(value / maxValue, 1)))
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                Button {
                    inspected = inspected == index ? nil : index
                } label: {
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(RichCharts.formattedValue(point.value))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Tokens.Palette.chartValue)
                        if kind == .line {
                            Circle()
                                .fill(inspected == index ? Tokens.Palette.chartBarSelected : Tokens.Palette.chartBar)
                                .frame(width: 10, height: 10)
                            Color.clear
                                .frame(height: max(0, fraction(point.value) * plotHeight - 10))
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(inspected == index ? Tokens.Palette.chartBarSelected : Tokens.Palette.chartBar)
                                .frame(maxWidth: 48)
                                .frame(height: max(2, fraction(point.value) * plotHeight))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: plotHeight + 22, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(point.label), \(RichCharts.formattedValue(point.value))")
                .accessibilityAddTraits(inspected == index ? .isSelected : [])
                .accessibilityIdentifier("rich.chart.\(block.id).bar.\(index)")
            }
        }
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                // Mid gridline (half of the max value) + baseline.
                RichHLine()
                    .stroke(Tokens.Palette.chartGrid, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(height: 1)
                    .offset(y: -plotHeight / 2)
                Rectangle()
                    .fill(Tokens.Palette.chartAxis)
                    .frame(height: 1)
            }
        }
    }

    private var shares: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let share = total > 0 ? max(point.value, 0) / total : 0
                Button {
                    inspected = inspected == index ? nil : index
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(point.label)
                                .font(.footnote)
                                .foregroundStyle(Tokens.Palette.textBody)
                            Spacer()
                            Text("\(RichCharts.formattedValue(point.value)) · \(Int((share * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Tokens.Palette.textSecondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Tokens.Palette.resultTrack)
                                Capsule()
                                    .fill(inspected == index ? Tokens.Palette.chartBarSelected : Tokens.Palette.chartBar)
                                    .frame(width: geo.size.width * CGFloat(share))
                            }
                        }
                        .frame(height: 7)
                    }
                    .frame(minHeight: Tokens.Layout.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(point.label), \(RichCharts.formattedValue(point.value)), \(Int((share * 100).rounded())) percent")
                .accessibilityIdentifier("rich.chart.\(block.id).bar.\(index)")
            }
        }
    }

    // MARK: Data table

    private var dataTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            tableRow("Label", "Value", header: true)
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                tableRow(point.label, RichCharts.formattedValue(point.value), header: false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.chart.\(block.id).table")
    }

    private func tableRow(_ label: String, _ value: String, header: Bool) -> some View {
        HStack {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(header ? Font.caption.weight(.bold) : Font.footnote)
        .foregroundStyle(header ? Tokens.Palette.textSecondary : Tokens.Palette.textBody)
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.Palette.border).frame(height: 1)
        }
    }
}

struct RichFormView: View {
    let block: RichBlock
    let fields: [RichFormField]
    let submitLabel: String
    let messageID: String
    @ObservedObject var interactions: RichInteractionStore
    let submitHandlerExists: Bool
    let submit: ([String: String]) -> Void

    /// Field-level errors appear after the first submit attempt, not before.
    @State private var attempted = false

    private var draft: [String: String] {
        interactions.formDraft(messageID: messageID, blockID: block.id)
    }

    private var missing: [String] {
        interactions.missingRequired(fields: fields, messageID: messageID, blockID: block.id)
    }

    private var submitted: Bool {
        interactions.isFormSubmitted(messageID: messageID, blockID: block.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    if field.kind != .checkbox {
                        HStack(spacing: 3) {
                            Text(field.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Tokens.Palette.textSecondary)
                            if field.required {
                                Text("*")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Tokens.Palette.danger)
                                    .accessibilityLabel("required")
                            }
                        }
                    }
                    fieldView(field)
                    if attempted && missing.contains(field.id) {
                        Text("Required")
                            .font(.caption2)
                            .foregroundStyle(Tokens.Palette.danger)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rich.form.\(block.id).field.\(field.id)")
            }
            .disabled(submitted)

            if submitted {
                Label("Submitted", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.Palette.success)
                    .accessibilityIdentifier("rich.form.\(block.id).submitted")
            } else if RichBlockRendererRegistry.rendersSubmit(handlerExists: submitHandlerExists) {
                Button(submitLabel) {
                    attempted = true
                    guard missing.isEmpty else { return }
                    guard interactions.markFormSubmitted(messageID: messageID, blockID: block.id) else { return }
                    submit(draft)
                }
                .buttonStyle(JarvisButtonStyle(.primary))
                .accessibilityIdentifier("rich.form.\(block.id).submit")
            }
        }
        .jarvisCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.form.\(block.id)")
    }

    private func inputChrome<Content: View>(_ content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: Tokens.Layout.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Tokens.Palette.sunken))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tokens.Palette.border, lineWidth: 1))
    }

    @ViewBuilder
    private func fieldView(_ field: RichFormField) -> some View {
        switch field.kind {
        case .checkbox:
            let checked = draft[field.id] == "1"
            Button {
                interactions.setFormValue(
                    messageID: messageID, blockID: block.id,
                    fieldID: field.id, value: checked ? "0" : "1")
            } label: {
                HStack(spacing: 10) {
                    RichCheckbox(checked: checked)
                    Text(field.label)
                        .font(.footnote)
                        .foregroundStyle(Tokens.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Tokens.Layout.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(checked ? .isSelected : [])
        case .select:
            Menu {
                ForEach(field.options ?? [], id: \.self) { option in
                    Button(option) {
                        interactions.setFormValue(
                            messageID: messageID, blockID: block.id,
                            fieldID: field.id, value: option)
                    }
                }
            } label: {
                inputChrome(
                    HStack {
                        Text(draft[field.id] ?? "Choose…")
                            .font(.footnote)
                            .foregroundStyle(draft[field.id] == nil
                                             ? Tokens.Palette.textMuted
                                             : Tokens.Palette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Tokens.Palette.textMuted)
                    })
            }
        default:
            inputChrome(
                TextField(text: Binding(
                    get: { draft[field.id] ?? "" },
                    set: { interactions.setFormValue(
                        messageID: messageID, blockID: block.id,
                        fieldID: field.id, value: $0) }),
                          prompt: Text(field.kind == .number ? "0" : field.label)
                            .foregroundColor(Tokens.Palette.textMuted)) {
                    Text(field.label)
                }
                .font(.footnote)
                .foregroundStyle(Tokens.Palette.textPrimary))
        }
    }
}

/// Rounded-square checkbox (filled cyan with a dark check when on).
struct RichCheckbox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(checked ? Tokens.Palette.accent : Color.clear)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(checked ? Tokens.Palette.accent : Tokens.Palette.textMuted, lineWidth: 1.5)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Tokens.Palette.onAccent)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: P1 renderers

struct RichNoticeView: View {
    let tone: RichNoticeTone
    let text: String
    let block: RichBlock

    private var systemImage: String {
        switch tone {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var toneColor: Color {
        switch tone {
        case .info: return Tokens.Palette.accent
        case .success: return Tokens.Palette.success
        case .warning: return Tokens.Palette.warning
        case .error: return Tokens.Palette.danger
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(toneColor)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Tokens.Palette.textBody)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .fill(toneColor.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                .strokeBorder(toneColor.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(block.a11yLabel ?? text)
        .accessibilityIdentifier("rich.notice.\(block.id)")
    }
}

struct RichCitationView: View {
    let title: String
    let url: URL
    let block: RichBlock

    var body: some View {
        // Safe scheme only (http/https) — anything else degrades to a plain
        // line (security controls: URL protocol sanitization).
        if let safe = RichBlocks.safeURL(url.absoluteString) {
            Link(destination: safe) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Tokens.Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(safe.host ?? "")
                            .font(.caption2)
                            .foregroundStyle(Tokens.Palette.textMuted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(Tokens.Palette.textMuted)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: Tokens.Layout.hitTarget + 8)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .fill(Tokens.Palette.elevated))
                .overlay(
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Tokens.Palette.border, lineWidth: 1))
            }
            .accessibilityIdentifier("rich.citation.\(block.id)")
        } else {
            RichFallbackCardView(
                block: block,
                reason: .decodingFailure,
                explicitSummary: block.fallbackDisplayText)
        }
    }
}

struct RichCardView: View {
    let title: String
    let subtitle: String?
    let cardBody: String
    let block: RichBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RichCardHeader(
                title: title,
                subtitle: subtitle.flatMap { RichBlocks.nonEmpty($0) })
            if RichBlocks.nonEmpty(cardBody) != nil {
                MarkdownText(cardBody, font: .footnote, color: Tokens.Palette.textBody)
            }
        }
        .jarvisCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(block.a11yLabel ?? block.fallbackDisplayText)
        .accessibilityIdentifier("rich.card.\(block.id)")
    }
}

struct RichChecklistView: View {
    let block: RichBlock
    let items: [RichChecklistItem]
    let messageID: String
    @ObservedObject var interactions: RichInteractionStore

    private var states: [Bool] {
        interactions.checklistState(
            messageID: messageID, blockID: block.id, count: items.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let checked = index < states.count ? states[index] : false
                Button {
                    interactions.toggleChecklist(
                        messageID: messageID, blockID: block.id,
                        index: index, count: items.count)
                } label: {
                    HStack(spacing: 11) {
                        RichCheckbox(checked: checked)
                        Text(item.text)
                            .font(.footnote)
                            .strikethrough(checked, color: Tokens.Palette.textMuted)
                            .foregroundStyle(checked ? Tokens.Palette.textMuted : Tokens.Palette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: Tokens.Layout.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(checked ? .isSelected : [])
                .accessibilityIdentifier("rich.checklist.\(block.id).item.\(index)")
            }
        }
        .jarvisCard(padding: 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.checklist.\(block.id)")
    }
}
