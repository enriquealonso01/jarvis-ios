import Foundation

// MARK: - Item 11: Rich Blocks (UI-Expansion §D — typed rich-content blocks)
//
// Package contract: contracts/rich-response.schema.json v1 (typed block AST) +
// docs/04_RICH_RESPONSE_CATALOG.md (renderer philosophy) + PLAN_DELTA §D.
//
// Binding laws implemented here:
//   • Typed blocks ONLY — no arbitrary HTML/JS ever (ADOPT, binding). The iOS
//     side renders the validated JSON AST through a native component registry
//     (RichBlocksViews.swift); unknown/undecodable types degrade to a
//     fallbackText card — never a crash, never a blank.
//   • One unsupported block NEVER rejects the whole assistant reply (catalog
//     "Versioning"): the lenient decoder salvages fallbackText per block.
//   • Interactive state is isolated per message, keyed by block id, and can
//     be reset (PLAN_DELTA §D: "block.id-keyed state store; reset on
//     regenerate").
//   • Every block carries a print strategy (native/snapshot/summary/omit) —
//     the seam Item 13's PDF pipeline consumes.
//
// Everything in THIS file is pure logic (no SwiftUI/UIKit) so the macOS test
// lane exercises it headlessly. The SwiftUI renderers live in
// RichBlocksViews.swift.

// MARK: Block type (wire `type` enum)

/// The block types this build renders. P0 = the item-11 delivery set,
/// P1 = notice/citation/card/checklist, plus `fallback` — an INTERNAL state
/// for unknown/undecodable blocks (never produced on the wire by the strict
/// encoder; the schema's type enum does not contain it).
public enum RichBlockType: String, Sendable, Codable, CaseIterable, Equatable {
    // P0
    case text
    case markdown
    case heading
    case code
    case table
    case image
    case buttonGroup
    case poll
    case chart
    case form
    // P1
    case notice
    case citation
    case card
    case checklist
    // Internal salvage state (never on the wire from JARVIS)
    case fallback
}

// MARK: Print policy (schema `print` object)

/// Schema: `"print": {"strategy": "native|snapshot|summary|omit", "summary": string}`.
/// Item 13's PDF pipeline reads this per block (native→as-is, snapshot→raster,
/// summary→fallbackText).
public struct RichPrintPolicy: Sendable, Equatable, Codable {
    public enum Strategy: String, Sendable, Codable, CaseIterable {
        case native, snapshot, summary, omit
    }

    public var strategy: Strategy
    public var summary: String?

    public init(strategy: Strategy, summary: String? = nil) {
        self.strategy = strategy
        self.summary = summary
    }
}

/// Default print strategy per block type (the item-11 pin Item 13 builds on):
/// everything textual prints natively; interactive/visual blocks rasterize;
/// salvage blocks print their summary.
public enum RichPrintDefaults: Sendable {
    public static func strategy(for type: RichBlockType) -> RichPrintPolicy.Strategy {
        switch type {
        case .text, .markdown, .heading, .code, .table, .notice, .citation, .card:
            return .native
        case .image, .buttonGroup, .poll, .chart, .form, .checklist:
            return .snapshot
        case .fallback:
            return .summary
        }
    }
}

// MARK: Actions (schema `$defs/action`, verbatim shape)

/// One tappable action of a `buttonGroup` block (or a block-level `actions`
/// array). Wire keys: id, label, kind, requiresApproval?, confirmText?.
public struct RichBlockAction: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case local, submit, navigate, copy, openUrl, serverAction
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var requiresApproval: Bool?
    public var confirmText: String?

    public init(id: String, label: String, kind: Kind,
                requiresApproval: Bool? = nil, confirmText: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.requiresApproval = requiresApproval
        self.confirmText = confirmText
    }
}

// MARK: Payload model types (schema `props` per type)

public struct RichChartPoint: Sendable, Equatable, Codable {
    public var label: String
    public var value: Double

    public init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

public enum RichChartKind: String, Sendable, Codable, CaseIterable {
    case bar, line, pie
}

public struct RichFormField: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case text, number, date, select, checkbox
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var required: Bool
    /// `select` options (ignored by other kinds).
    public var options: [String]?

    public init(id: String, kind: Kind, label: String, required: Bool = false,
                options: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.required = required
        self.options = options
    }

    /// Lenient decode: `required` defaults false when the producer omits it
    /// (synthesized Codable would hard-require the key).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        label = try c.decode(String.self, forKey: .label)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        options = try c.decodeIfPresent([String].self, forKey: .options)
    }
}

public struct RichChecklistItem: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var text: String
    public var isChecked: Bool

    public init(id: String = UUID().uuidString, text: String, isChecked: Bool = false) {
        self.id = id
        self.text = text
        self.isChecked = isChecked
    }

    /// Lenient decode: absent `isChecked` means unchecked.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        isChecked = try c.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
    }
}

// MARK: Block content (type discriminator + typed props in one enum)

/// The typed payload of one block. `type` is derived from the case, `props`
/// encode/decode through the type-specific wire keys below.
public enum RichBlockContent: Sendable, Equatable {
    case text(String)
    case markdown(String)
    case heading(text: String, level: Int)
    case code(code: String, language: String?)
    case table(headers: [String], rows: [[String]])
    case image(url: URL, alt: String, caption: String?)
    case buttonGroup(buttons: [RichBlockAction])
    case poll(question: String, options: [String])
    case chart(kind: RichChartKind, title: String?, points: [RichChartPoint])
    case form(fields: [RichFormField], submitLabel: String)
    case notice(tone: RichNoticeTone, text: String)
    case citation(title: String, url: URL)
    case card(title: String, subtitle: String?, body: String)
    case checklist(items: [RichChecklistItem])
    /// Internal salvage payload (unknown type / undecodable props / malformed
    /// JSON) — renders as a standard fallback card, never crashes.
    case fallback(summary: String)

    public var type: RichBlockType {
        switch self {
        case .text: return .text
        case .markdown: return .markdown
        case .heading: return .heading
        case .code: return .code
        case .table: return .table
        case .image: return .image
        case .buttonGroup: return .buttonGroup
        case .poll: return .poll
        case .chart: return .chart
        case .form: return .form
        case .notice: return .notice
        case .citation: return .citation
        case .card: return .card
        case .checklist: return .checklist
        case .fallback: return .fallback
        }
    }

    /// A one-line plain-text digest used for copy/share/print-summary and as
    /// the never-blank fallback synthesis source.
    public var plainSummary: String {
        switch self {
        case .text(let s), .markdown(let s), .notice(_, let s):
            return s
        case .heading(let text, _):
            return text
        case .code(let code, _):
            return code
        case .table(let headers, let rows):
            return (headers + rows.flatMap { $0 }).joined(separator: " · ")
        case .image(_, let alt, _):
            return alt
        case .buttonGroup(let buttonList):
            return buttonList.map { $0.label }.joined(separator: ", ")
        case .poll(let question, let options):
            return question + ": " + options.joined(separator: ", ")
        case .chart(_, let title, let points):
            return RichCharts.accessibleSummary(title: title, points: points)
        case .form(let formFields, _):
            return formFields.map { $0.label }.joined(separator: ", ")
        case .citation(let title, let url):
            return title + " — " + url.absoluteString
        case .card(let title, _, let body):
            return title + ". " + body
        case .checklist(let checkItems):
            return checkItems.map { $0.text }.joined(separator: ", ")
        case .fallback(let summary):
            return summary
        }
    }

    public enum PropKey: String, CodingKey {
        // text / markdown / heading / code / notice / card / fallback
        case text, markdown, code, language, level
        case tone, title, subtitle, body, summary
        // table
        case headers, rows
        // image / citation
        case url, alt, caption
        // buttonGroup
        case buttons
        // poll
        case question, options
        // chart
        case kind, points
        // form / checklist
        case fields, submitLabel, items
    }

    /// Decode `props` for a known wire type. Throws on wrong-shape props —
    /// the lenient decoder (RichBlockSalvage) turns that into a fallback.
    public static func decode(type: RichBlockType,
                              from container: inout KeyedDecodingContainer<PropKey>) throws -> RichBlockContent {
        let c = container
        switch type {
        case .text:
            return .text(try c.decode(String.self, forKey: .text))
        case .markdown:
            return .markdown(try c.decode(String.self, forKey: .markdown))
        case .heading:
            return .heading(
                text: try c.decode(String.self, forKey: .text),
                level: try c.decodeIfPresent(Int.self, forKey: .level) ?? 2)
        case .code:
            return .code(
                code: try c.decode(String.self, forKey: .code),
                language: try c.decodeIfPresent(String.self, forKey: .language))
        case .table:
            return .table(
                headers: try c.decode([String].self, forKey: .headers),
                rows: try c.decode([[String]].self, forKey: .rows))
        case .image:
            // One URL-safety definition: http(s) only, ever (the same gate
            // the view layer applies before opening). Anything else throws —
            // the lenient decoder turns that into a fallback block.
            guard let url = RichBlocks.safeURL(try c.decode(String.self, forKey: .url)) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c,
                    debugDescription: "image url is not a valid http(s) URL")
            }
            return .image(
                url: url,
                alt: try c.decodeIfPresent(String.self, forKey: .alt) ?? "Image",
                caption: try c.decodeIfPresent(String.self, forKey: .caption))
        case .buttonGroup:
            return .buttonGroup(buttons: try c.decode([RichBlockAction].self, forKey: .buttons))
        case .poll:
            return .poll(
                question: try c.decode(String.self, forKey: .question),
                options: try c.decode([String].self, forKey: .options))
        case .chart:
            return .chart(
                kind: try c.decodeIfPresent(RichChartKind.self, forKey: .kind) ?? .bar,
                title: try c.decodeIfPresent(String.self, forKey: .title),
                points: try c.decode([RichChartPoint].self, forKey: .points))
        case .form:
            return .form(
                fields: try c.decode([RichFormField].self, forKey: .fields),
                submitLabel: try c.decodeIfPresent(String.self, forKey: .submitLabel) ?? "Submit")
        case .notice:
            return .notice(
                tone: try c.decodeIfPresent(RichNoticeTone.self, forKey: .tone) ?? .info,
                text: try c.decode(String.self, forKey: .text))
        case .citation:
            // Same single URL-safety gate as image: http(s) only.
            guard let url = RichBlocks.safeURL(try c.decode(String.self, forKey: .url)) else {
                throw DecodingError.dataCorruptedError(forKey: .url, in: c,
                    debugDescription: "citation url is not a valid http(s) URL")
            }
            return .citation(
                title: try c.decode(String.self, forKey: .title),
                url: url)
        case .card:
            return .card(
                title: try c.decode(String.self, forKey: .title),
                subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
                body: try c.decodeIfPresent(String.self, forKey: .body) ?? "")
        case .checklist:
            return .checklist(items: try c.decode([RichChecklistItem].self, forKey: .items))
        case .fallback:
            return .fallback(summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "")
        }
    }

    public func encodeProps(to container: inout KeyedEncodingContainer<PropKey>) throws {
        switch self {
        case .text(let s):
            try container.encode(s, forKey: .text)
        case .markdown(let s):
            try container.encode(s, forKey: .markdown)
        case .heading(let text, let level):
            try container.encode(text, forKey: .text)
            try container.encode(level, forKey: .level)
        case .code(let code, let language):
            try container.encode(code, forKey: .code)
            try container.encodeIfPresent(language, forKey: .language)
        case .table(let headers, let rows):
            try container.encode(headers, forKey: .headers)
            try container.encode(rows, forKey: .rows)
        case .image(let url, let alt, let caption):
            try container.encode(url.absoluteString, forKey: .url)
            try container.encode(alt, forKey: .alt)
            try container.encodeIfPresent(caption, forKey: .caption)
        case .buttonGroup(let buttons):
            try container.encode(buttons, forKey: .buttons)
        case .poll(let question, let options):
            try container.encode(question, forKey: .question)
            try container.encode(options, forKey: .options)
        case .chart(let kind, let title, let points):
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(points, forKey: .points)
        case .form(let fields, let submitLabel):
            try container.encode(fields, forKey: .fields)
            try container.encode(submitLabel, forKey: .submitLabel)
        case .notice(let tone, let text):
            try container.encode(tone, forKey: .tone)
            try container.encode(text, forKey: .text)
        case .citation(let title, let url):
            try container.encode(title, forKey: .title)
            try container.encode(url.absoluteString, forKey: .url)
        case .card(let title, let subtitle, let body):
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
            try container.encode(body, forKey: .body)
        case .checklist(let items):
            try container.encode(items, forKey: .items)
        case .fallback(let summary):
            try container.encode(summary, forKey: .summary)
        }
    }
}

public enum RichNoticeTone: String, Sendable, Codable, CaseIterable {
    case info, success, warning, error
}

// MARK: The block (schema `$defs/block`)

/// One typed rich-content block. Wire shape (schema v1, verbatim):
/// `{"id", "type", "version", "props", "fallbackText",
///   "a11yLabel"?, "interactiveStateRef"?, "print"?, "actions"?}`.
public struct RichBlock: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let version: String
    public let fallbackText: String
    public let a11yLabel: String?
    public let print: RichPrintPolicy?
    public let actions: [RichBlockAction]?
    public let content: RichBlockContent

    public var type: RichBlockType { content.type }

    enum CodingKeys: String, CodingKey {
        case id, type, version, props, fallbackText
        case a11yLabel
        case interactiveStateRef
        case print, actions
    }

    public init(id: String = UUID().uuidString,
                content: RichBlockContent,
                version: String = "1.0.0",
                fallbackText: String? = nil,
                a11yLabel: String? = nil,
                print: RichPrintPolicy? = nil,
                actions: [RichBlockAction]? = nil) {
        self.id = id
        self.content = content
        self.version = version
        // Contract: every block HAS a fallbackText. When the producer omits
        // one, synthesize from the content so the fallback card can never be
        // blank (never-crash, never-blank law).
        self.fallbackText = RichBlocks.nonEmpty(fallbackText)
            ?? RichBlocks.nonEmpty(content.plainSummary)
            ?? "This content couldn't be displayed."
        self.a11yLabel = a11yLabel
        self.print = print ?? RichPrintPolicy(strategy: RichPrintDefaults.strategy(for: content.type))
        self.actions = actions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try c.decode(String.self, forKey: .id)
        let decodedVersion = try c.decode(String.self, forKey: .version)
        let decodedFallback = try c.decodeIfPresent(String.self, forKey: .fallbackText) ?? ""
        let decodedA11y = try c.decodeIfPresent(String.self, forKey: .a11yLabel)
        let decodedPrint = try c.decodeIfPresent(RichPrintPolicy.self, forKey: .print)
        let decodedActions = try c.decodeIfPresent([RichBlockAction].self, forKey: .actions)
        let rawType = try c.decode(String.self, forKey: .type)
        guard let type = RichBlockType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "unsupported block type '\(rawType)'")
        }
        // `props` may be absent only for the internal fallback state; every
        // real block carries its props object. Decoded as a nested container
        // (same keyed container family as the wire object, props-typed keys).
        let decodedContent: RichBlockContent
        if c.contains(.props) {
            var nested = try c.nestedContainer(keyedBy: RichBlockContent.PropKey.self,
                                               forKey: .props)
            decodedContent = try RichBlockContent.decode(type: type, from: &nested)
        } else if type == .fallback {
            decodedContent = .fallback(summary: decodedFallback)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.props, .init(
                codingPath: c.codingPath, debugDescription: "block is missing props"))
        }
        // Same invariants as the memberwise init — a decoded block is a
        // first-class block: non-blank fallbackText, defaulted print
        // strategy (schema `print` is optional on the wire, never in-model).
        id = decodedID
        version = decodedVersion
        fallbackText = RichBlocks.nonEmpty(decodedFallback)
            ?? RichBlocks.nonEmpty(decodedContent.plainSummary)
            ?? "This content couldn't be displayed."
        a11yLabel = decodedA11y
        print = decodedPrint ?? RichPrintPolicy(strategy: RichPrintDefaults.strategy(for: type))
        actions = decodedActions
        content = decodedContent
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type.rawValue, forKey: .type)
        try c.encode(version, forKey: .version)
        // The internal fallback state has no schema type — encode its summary
        // as the (schema-legal) props of a text-shaped object. Real blocks
        // encode their typed props.
        var props = c.nestedContainer(keyedBy: RichBlockContent.PropKey.self, forKey: .props)
        try content.encodeProps(to: &props)
        try c.encode(fallbackText, forKey: .fallbackText)
        try c.encodeIfPresent(a11yLabel, forKey: .a11yLabel)
        try c.encodeIfPresent(print, forKey: .print)
        try c.encodeIfPresent(actions, forKey: .actions)
    }

    /// The text a fallback card shows: the block's fallbackText, never empty
    /// (the init guarantees synthesis, this is the read seam for QA).
    public var fallbackDisplayText: String {
        RichBlocks.nonEmpty(fallbackText) ?? "This content couldn't be displayed."
    }
}

// MARK: Envelope (schema root: JARVIS Rich Assistant Message v1)

public struct RichBlocksEnvelope: Sendable, Equatable, Codable {
    public static let schemaVersion = "1.0.0"

    public var schemaVersion: String
    public var messageId: String
    public var conversationId: String?
    public var projectId: String?
    public var blocks: [RichBlock]

    public init(messageId: String, conversationId: String? = nil,
                projectId: String? = nil, blocks: [RichBlock]) {
        self.schemaVersion = RichBlocksEnvelope.schemaVersion
        self.messageId = messageId
        self.conversationId = conversationId
        self.projectId = projectId
        self.blocks = blocks
    }

    public func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

// MARK: Small shared helpers

public enum RichBlocks: Sendable {
    public static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// URL safety (catalog "Security controls"): only http(s) may open. Every
    /// rendered link/citation passes through this — javascript:/data:/file:
    /// and friends are rejected before a Link is ever created.
    public static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

public enum RichCharts: Sendable {
    /// Accessible summary with REAL counts (design doc §Accessibility: chart
    /// summaries must not be color-only).
    public static func accessibleSummary(title: String?, points: [RichChartPoint]) -> String {
        let head = title ?? "Chart"
        guard !points.isEmpty else { return head + " (no data)" }
        let body = points.map { "\($0.label): \(formattedValue($0.value))" }
            .joined(separator: ", ")
        return "\(head) — \(body)"
    }

    public static func formattedValue(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9
            ? String(Int(v))
            : String(format: "%.2f", v)
    }
}

// MARK: Lenient decode (never crash, never blank, never reject the reply)

/// The entry point for untrusted block payloads. Unknown type, wrong-shape
/// props, or malformed JSON all degrade to `.fallback` blocks that keep the
/// producer's fallbackText when present — the rest of the reply still renders.
public enum RichBlockSalvage: Sendable {

    /// Decode an envelope/blocks array leniently. One JSON object per block is
    /// salvaged individually; total garbage yields [] (never throws).
    public static func decodeBlocks(from data: Data) -> [RichBlock] {
        guard let obj = jsonObject(from: data) else { return [] }
        return blocks(in: obj)
    }

    /// Leniently decode a blocks array out of an already-parsed JSON object
    /// (envelope with `blocks`, or a single bare block object).
    public static func blocks(in obj: [String: Any]) -> [RichBlock] {
        if let arr = obj["blocks"] as? [[String: Any]] {
            return arr.map(block(from:))
        }
        if obj["type"] is String {
            return [block(from: obj)]
        }
        return []
    }

    /// One block, salvage-on-failure. The fallback keeps: the producer id (or
    /// a fresh UUID), the producer fallbackText (or a synthesized summary —
    /// never blank).
    public static func block(from dict: [String: Any]) -> RichBlock {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed]),
           let strict = try? JSONDecoder().decode(RichBlock.self, from: data) {
            return strict
        }
        let id = (dict["id"] as? String).flatMap(RichBlocks.nonEmpty) ?? UUID().uuidString
        let typeRaw = dict["type"] as? String
        let summary = (dict["fallbackText"] as? String).flatMap(RichBlocks.nonEmpty)
            ?? synthesizedSummary(typeRaw: typeRaw)
        return RichBlock(id: id, content: .fallback(summary: summary))
    }

    static func synthesizedSummary(typeRaw: String?) -> String {
        if let t = RichBlocks.nonEmpty(typeRaw) {
            return "This \(t) block isn't supported by this version of JARVIS."
        }
        return "This content block couldn't be displayed."
    }

    static func jsonObject(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: Message-content detection (transcript seam)

/// Detects a rich envelope inside a message's plain-text content. Three legal
/// carriers: a raw JSON envelope, or a ```jarvis-rich fenced block (with or
/// without a language tag). Anything else is plain chat text — `nil` means
/// "render the text as-is", the normal case for every existing message.
public enum RichContentPayload: Sendable {

    public static let fenceMarker = "jarvis-rich"

    /// The blocks a transcript row should render INSTEAD of its raw text, or
    /// nil when the content is ordinary text (or an envelope too broken to
    /// produce any block — plain render wins there too).
    public static func parse(_ content: String) -> [RichBlock]? {
        guard let data = extractJSON(from: content) else { return nil }
        // Cheap pre-check so ordinary text never pays for JSON parsing.
        guard data.range(of: Data("blocks\"".utf8)) != nil else { return nil }
        let blocks = RichBlockSalvage.decodeBlocks(from: data)
        return blocks.isEmpty ? nil : blocks
    }

    /// The candidate JSON payload, if the content plausibly carries one.
    static func extractJSON(from content: String) -> Data? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 2 else { return nil }
            // Drop the opening fence (```jarvis-rich / ```json / ```).
            lines.removeFirst()
            // Drop a trailing fence if present (tolerate unclosed fences
            // mid-stream — they simply fail JSON validation later).
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeLast()
            }
            let body = lines.joined(separator: "\n")
            return RichBlocks.nonEmpty(body)?.data(using: .utf8)
        }
        if trimmed.hasPrefix("{") {
            return content.data(using: .utf8)
        }
        return nil
    }
}

// MARK: Renderer registry (pure decision layer)

/// Why the registry fell back (QA surface + a11y reason text).
public enum RichFallbackReason: Sendable, Equatable {
    case unsupportedType(RichBlockType)
    case decodingFailure
}

/// What the renderer layer does with one block.
public enum RichRenderPlan: Sendable, Equatable {
    case native(RichBlock)
    case fallbackCard(reason: RichFallbackReason)
}

/// Registry keyed by block type. Native SwiftUI renderers only — there is no
/// WKWebView/agent-HTML path anywhere in this system (binding ADOPT).
/// `renderPlan(for:)` is the single decision seam the view layer consumes;
/// unknown/undecodable types resolve to a standard fallback card.
public enum RichBlockRendererRegistry: Sendable {

    /// Item 11 P0 delivery set.
    public static let p0Types: Set<RichBlockType> = [
        .text, .markdown, .heading, .code, .table, .image,
        .buttonGroup, .poll, .chart, .form,
    ]

    /// P1 set (same item, second tranche).
    public static let p1Types: Set<RichBlockType> = [
        .notice, .citation, .card, .checklist,
    ]

    /// Everything this build renders natively. `fallback` is deliberately
    /// absent — it IS the fallback.
    public static let supportedTypes: Set<RichBlockType> = p0Types.union(p1Types)

    public static func canRender(_ type: RichBlockType) -> Bool {
        supportedTypes.contains(type)
    }

    /// The plan for one block: native renderer, or the standard fallback card.
    public static func renderPlan(for block: RichBlock) -> RichRenderPlan {
        // The internal fallback state IS the fallback card (salvage payload).
        if block.type == .fallback {
            return .fallbackCard(reason: .decodingFailure)
        }
        guard canRender(block.type) else {
            return .fallbackCard(reason: .unsupportedType(block.type))
        }
        return .native(block)
    }

    // MARK: No-fake-button decisions (cross-cutting ADOPT)

    /// A buttonGroup renders its buttons ONLY when a real action handler
    /// exists on this surface; otherwise the block degrades to its
    /// fallbackText line (never a dead button — same law as Item 9's •••).
    public static func rendersButtons(handlerExists: Bool) -> Bool { handlerExists }

    /// A form renders its submit control ONLY when a real submit handler
    /// exists; otherwise fallbackText line (drafts stay editable — that part
    /// is genuinely local).
    public static func rendersSubmit(handlerExists: Bool) -> Bool { handlerExists }
}

// MARK: Interactive state (per-message isolated, resettable)

/// Block-interaction state store (PLAN_DELTA §D: "block.id-keyed state store
/// in VM; reset on regenerate"). Keys are `"<messageID>|<blockID>"` so state
/// NEVER crosses messages, and a regenerated answer (new message id) starts
/// clean by construction.
@MainActor
public final class RichInteractionStore: ObservableObject {

    public struct Key: Sendable, Equatable, Hashable {
        public let messageID: String
        public let blockID: String
        public var rawValue: String { "\(messageID)|\(blockID)" }
        public init(messageID: String, blockID: String) {
            self.messageID = messageID
            self.blockID = blockID
        }
    }

    @Published public private(set) var pollSelections: [String: Int] = [:]
    @Published public private(set) var checklistStates: [String: [Bool]] = [:]
    @Published public private(set) var formDrafts: [String: [String: String]] = [:]

    public init() {}

    public func key(_ messageID: String, _ blockID: String) -> String {
        Key(messageID: messageID, blockID: blockID).rawValue
    }

    // MARK: Poll (local selection; submit/aggregation is a server concern)

    public func selectPoll(messageID: String, blockID: String, optionIndex: Int) {
        pollSelections[key(messageID, blockID)] = optionIndex
    }

    public func pollSelection(messageID: String, blockID: String) -> Int? {
        pollSelections[key(messageID, blockID)]
    }

    // MARK: Checklist

    public func toggleChecklist(messageID: String, blockID: String, index: Int, count: Int) {
        let k = key(messageID, blockID)
        var states = checklistStates[k] ?? Array(repeating: false, count: count)
        guard index >= 0 && index < states.count else { return }
        states[index].toggle()
        checklistStates[k] = states
    }

    public func checklistState(messageID: String, blockID: String, count: Int) -> [Bool] {
        checklistStates[key(messageID, blockID)] ?? Array(repeating: false, count: count)
    }

    // MARK: Form drafts

    public func setFormValue(messageID: String, blockID: String, fieldID: String, value: String) {
        let k = key(messageID, blockID)
        var draft = formDrafts[k] ?? [:]
        draft[fieldID] = value
        formDrafts[k] = draft
    }

    public func formDraft(messageID: String, blockID: String) -> [String: String] {
        formDrafts[key(messageID, blockID)] ?? [:]
    }

    /// Required-field validation (catalog: field-level errors, prevent
    /// malformed submits). Returns the missing field ids.
    public func missingRequired(fields: [RichFormField], messageID: String, blockID: String) -> [String] {
        let draft = formDraft(messageID: messageID, blockID: blockID)
        return fields.filter { field in
            guard field.required else { return false }
            return RichBlocks.nonEmpty(draft[field.id]) == nil
        }.map { $0.id }
    }

    // MARK: Reset (regenerate / teardown)

    /// Regenerate seam: clear everything (or one message's slice).
    public func resetAll() {
        pollSelections = [:]
        checklistStates = [:]
        formDrafts = [:]
    }

    public func reset(messageID: String) {
        let prefix = "\(messageID)|"
        pollSelections = pollSelections.filter { !$0.key.hasPrefix(prefix) }
        checklistStates = checklistStates.filter { !$0.key.hasPrefix(prefix) }
        formDrafts = formDrafts.filter { !$0.key.hasPrefix(prefix) }
    }
}
