import SwiftUI
import DesignSystem

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
// All views are inert without injected handlers (no-fake-button law): a
// buttonGroup with no action handler renders its fallback line; a form with
// no submit handler keeps its drafts editable but shows no submit control.

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

    public init(blocks: [RichBlock],
                messageID: String,
                interactions: RichInteractionStore,
                onAction: ((String, RichBlockAction) -> Void)? = nil,
                onFormSubmit: ((String, [String: String]) -> Void)? = nil) {
        self.blocks = blocks
        self.messageID = messageID
        self.interactions = interactions
        self.onAction = onAction
        self.onFormSubmit = onFormSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            ForEach(blocks) { block in
                RichBlockView(
                    block: block,
                    messageID: messageID,
                    interactions: interactions,
                    onAction: onAction,
                    onFormSubmit: onFormSubmit)
            }
        }
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
                handlerExists: onAction != nil) { action in
                    onAction?(messageID, action)
                }
        case .poll(let question, let options):
            RichPollView(
                block: block, question: question, options: options,
                messageID: messageID, interactions: interactions)
        case .chart(let kind, let title, let points):
            RichChartView(kind: kind, title: title, points: points, block: block)
        case .form(let fields, let submitLabel):
            RichFormView(
                block: block, fields: fields, submitLabel: submitLabel,
                messageID: messageID, interactions: interactions,
                submitHandlerExists: onFormSubmit != nil) { draft in
                    onFormSubmit?(messageID, draft)
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
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Unsupported content")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(summaryText)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1))
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
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(block.a11yLabel ?? text)
            .accessibilityIdentifier("rich.text.\(block.id)")
    }
}

/// Markdown via the system parser (native, sanctioned — this is SwiftUI's own
/// Markdown, not agent HTML). Inline styles only; block structure that needs
/// more comes as typed blocks.
struct RichMarkdownView: View {
    let markdown: String
    let block: RichBlock

    var body: some View {
        Text(LocalizedStringKey(markdown))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(block.a11yLabel ?? block.fallbackDisplayText)
            .accessibilityIdentifier("rich.markdown.\(block.id)")
    }
}

struct RichHeadingView: View {
    let text: String
    let level: Int
    let block: RichBlock

    private var font: Font {
        switch max(1, min(level, 4)) {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    var body: some View {
        Text(text)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            .background(Color.secondary.opacity(0.10))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(Tokens.Spacing.m)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
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
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                if !headers.isEmpty {
                    headerRow
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(index: index, row: row)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.a11yLabel ?? block.fallbackDisplayText)
        .accessibilityIdentifier("rich.table.\(block.id)")
    }

    private func tableRow(index: Int, row: [String]) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.footnote)
                    .frame(width: 120, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Tokens.Spacing.s)
        .padding(.horizontal, Tokens.Spacing.m)
        .background(rowBackground(index: index))
    }

    private func rowBackground(index: Int) -> Color {
        index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05)
    }

    private var headerRow: some View {
        HStack(spacing: Tokens.Spacing.m) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .frame(width: 120, alignment: .leading)
            }
        }
        .padding(.vertical, Tokens.Spacing.s)
        .padding(.horizontal, Tokens.Spacing.m)
        .background(Color.secondary.opacity(0.10))
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
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel(block.a11yLabel ?? alt)

            if let caption, RichBlocks.nonEmpty(caption) != nil {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("rich.image.\(block.id)")
    }

    private func placeholderView(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.10))
            VStack(spacing: Tokens.Spacing.s) {
                Image(systemName: systemName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(Tokens.Spacing.l)
        }
        .frame(minHeight: 120)
    }
}

/// Buttons render ONLY with a real injected handler (no fake buttons); the
/// engine's `rendersButtons(handlerExists:)` gate is the law.
struct RichButtonGroupView: View {
    let block: RichBlock
    let buttons: [RichBlockAction]
    let messageID: String
    let handlerExists: Bool
    let fire: (RichBlockAction) -> Void

    var body: some View {
        if RichBlockRendererRegistry.rendersButtons(handlerExists: handlerExists) {
            FlowLikeRow {
                ForEach(buttons) { button in
                    Button {
                        fire(button)
                    } label: {
                        Text(button.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, Tokens.Spacing.m)
                            .padding(.vertical, Tokens.Spacing.s)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rich.button.\(block.id).\(button.id)")
                }
            }
            .accessibilityIdentifier("rich.buttonGroup.\(block.id)")
        } else {
            RichFallbackCardView(
                block: block,
                reason: .decodingFailure,
                explicitSummary: block.fallbackDisplayText)
        }
    }
}

/// Simple wrapping row approximation without GeometryReader: an HStack with
/// wrapping via `ViewThatFits`-free manual layout — buttons are few; the row
/// scrolls horizontally when crowded (deterministic, no magic).
private struct FlowLikeRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Spacing.s) { content }
        }
    }
}

struct RichPollView: View {
    let block: RichBlock
    let question: String
    let options: [String]
    let messageID: String
    @ObservedObject var interactions: RichInteractionStore

    private var selection: Int? {
        interactions.pollSelection(messageID: messageID, blockID: block.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(question)
                .font(.subheadline.weight(.semibold))
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                pollOption(index: index, option: option)
            }
        }
        .padding(Tokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(block.a11yLabel ?? question)
        .accessibilityIdentifier("rich.poll.\(block.id)")
    }

    private func pollOption(index: Int, option: String) -> some View {
        Button {
            interactions.selectPoll(
                messageID: messageID, blockID: block.id, optionIndex: index)
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: optionIcon(index))
                    .foregroundStyle(Color.accentColor)
                Text(option)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            .background(optionBackground(index))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rich.poll.\(block.id).option.\(index)")
    }

    private func optionIcon(_ index: Int) -> String {
        selection == index ? "largecircle.fill.circle" : "circle"
    }

    private func optionBackground(_ index: Int) -> Color {
        selection == index
            ? Color.accentColor.opacity(0.14)
            : Color.secondary.opacity(0.08)
    }
}

/// Charts drawn with native primitives (bars) + a REAL data summary — no
/// framework dependency, deterministic, accessible (counts in the a11y text,
/// not color-only).
struct RichChartView: View {
    let kind: RichChartKind
    let title: String?
    let points: [RichChartPoint]
    let block: RichBlock

    private var maxValue: Double {
        points.map { $0.value }.max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                HStack(spacing: Tokens.Spacing.s) {
                    Text(point.label)
                        .font(.caption)
                        .frame(width: 88, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.10))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: barWidth(point.value, available: geo.size.width))
                        }
                    }
                    .frame(height: 10)
                    Text(RichCharts.formattedValue(point.value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(RichCharts.accessibleSummary(title: title, points: points))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Tokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.chart.\(block.id)")
    }

    private func barWidth(_ value: Double, available: CGFloat) -> CGFloat {
        guard maxValue > 0, available > 0 else { return 0 }
        let fraction = CGFloat(max(0, min(value / maxValue, 1)))
        return available * fraction
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

    private var draft: [String: String] {
        interactions.formDraft(messageID: messageID, blockID: block.id)
    }

    private var missing: [String] {
        interactions.missingRequired(fields: fields, messageID: messageID, blockID: block.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(field.label)
                            .font(.caption.weight(.medium))
                        if field.required {
                            Text("*")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.red)
                        }
                    }
                    fieldView(field)
                    if missing.contains(field.id) {
                        Text("Required")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .accessibilityIdentifier("rich.form.\(block.id).field.\(field.id)")
            }

            if RichBlockRendererRegistry.rendersSubmit(handlerExists: submitHandlerExists) {
                Button {
                    guard missing.isEmpty else { return }
                    submit(draft)
                } label: {
                    Text(submitLabel)
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Tokens.Spacing.s)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.accentColor.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rich.form.\(block.id).submit")
            }
        }
        .padding(Tokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.form.\(block.id)")
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
                HStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(Color.accentColor)
                    Text(field.label).font(.footnote)
                }
            }
            .buttonStyle(.plain)
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
                HStack {
                    Text(draft[field.id] ?? field.label)
                        .font(.footnote)
                        .foregroundStyle(draft[field.id] == nil ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Tokens.Spacing.m)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.10)))
            }
        default:
            TextField(field.kind == .number ? "0" : "",
                      text: Binding(
                        get: { draft[field.id] ?? "" },
                        set: { interactions.setFormValue(
                            messageID: messageID, blockID: block.id,
                            fieldID: field.id, value: $0) }))
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08)))
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
                HStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(safe.host ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
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
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let subtitle, RichBlocks.nonEmpty(subtitle) != nil {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(cardBody)
                .font(.footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1))
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
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    interactions.toggleChecklist(
                        messageID: messageID, blockID: block.id,
                        index: index, count: items.count)
                } label: {
                    HStack(spacing: Tokens.Spacing.s) {
                        Image(systemName: states[index]
                            ? "checkmark.square.fill" : "square")
                            .foregroundStyle(Color.accentColor)
                        Text(item.text)
                            .font(.footnote)
                            .strikethrough(states[index])
                            .foregroundStyle(states[index] ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rich.checklist.\(block.id).item.\(index)")
            }
        }
        .padding(Tokens.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rich.checklist.\(block.id)")
    }
}
