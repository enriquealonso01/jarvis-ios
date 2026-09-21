import SwiftUI

/// Claude-Code-style transcript: assistant/user text prominent; every tool
/// call/result collapsed into one "N tool activity" disclosure at the end of
/// each assistant turn — the noise never interrupts the conversation flow.
struct TranscriptView: View {
    let sessionId: String

    struct Message: Identifiable, Decodable {
        let id: Int
        let role: String
        let content: String?
        let toolName: String?
        let toolCalls: String?
        let timestamp: Double?

        enum CodingKeys: String, CodingKey {
            case id, role, content, timestamp
            case toolName = "tool_name"
            case toolCalls = "tool_calls"
        }

        /// tool_calls arrives as a JSON-encoded string on current builds, but
        /// some dashboard versions emit a real array — re-encode arrays to a
        /// string so projection code has ONE shape to parse.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            role = try c.decode(String.self, forKey: .role)
            content = try c.decodeIfPresent(String.self, forKey: .content)
            toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
            timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
            if let s = try c.decodeIfPresent(String.self, forKey: .toolCalls) {
                toolCalls = s
            } else if let arr = try c.decodeIfPresent(FlexibleArray.self,
                                                      forKey: .toolCalls) {
                toolCalls = String(data: JSONEncoder().encode(arr), encoding: .utf8)
            } else {
                toolCalls = nil
            }
        }
    }

    /// Lossy JSON array wrapper (any element shape).
    struct FlexibleArray: Codable {
        let items: [AnyEncodableBox]
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            items = []
            while !container.isAtEnd {
                items.append(try container.decode(AnyEncodableBox.self))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            for item in items { try c.encode(item) }
        }
    }

    struct AnyEncodableBox: Codable {
        let value: Any
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { value = b }
            else if let i = try? c.decode(Int.self) { value = i }
            else if let d = try? c.decode(Double.self) { value = d }
            else if let s = try? c.decode(String.self) { value = s }
            else if let arr = try? c.decode([AnyEncodableBox].self) { value = arr }
            else if let dict = try? c.decode([String: AnyEncodableBox].self) { value = dict }
            else { value = NSNull() }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch value {
            case let b as Bool: try c.encode(b)
            case let i as Int: try c.encode(i)
            case let d as Double: try c.encode(d)
            case let s as String: try c.encode(s)
            case let arr as [AnyEncodableBox]: try c.encode(arr)
            case let dict as [String: AnyEncodableBox]: try c.encode(dict)
            default: try c.encodeNil()
            }
        }
    }

    /// One rendered unit: either a text bubble (user/assistant) or a collapsed
    /// tool-activity group.
    struct Turn: Identifiable {
        let id: String
        let role: String          // "user" | "assistant" | "tool"
        var text: String?
        var toolCount: Int = 0
        var toolNames: [String] = []
        var details: [ToolDetail] = []
    }

    struct ToolDetail: Identifiable {
        let id: String
        let name: String
        let summary: String       // one-line, e.g. the command or file path
        let output: String        // full output, shown when expanded
    }

    @State private var turns: [Turn] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showFeedback = false
    @State private var showCallMe = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if loading && turns.isEmpty {
                        ProgressView("Loading transcript…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let e = errorText, turns.isEmpty {
                        VStack(spacing: 10) {
                            Text(e).foregroundStyle(.secondary)
                            Button("Retry") { Task { await load() } }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(turns) { turn in
                            turnView(turn)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: turns.count) { _, _ in
                if let last = turns.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .navigationTitle(sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        showCallMe = true
                    } label: {
                        Image(systemName: "phone.badge.plus")
                    }
                    Button {
                        showFeedback = true
                    } label: {
                        Image(systemName: "exclamationmark.bubble")
                    }
                }
            }
        }
        .sheet(isPresented: $showFeedback) {
            FeedbackSheet(sessionId: sessionId)
        }
        .sheet(isPresented: $showCallMe) {
            CallMeSheet(sessionContext: "About session \(sessionId)")
        }
        .task { if turns.isEmpty { await load() } }
    }

    private var sessionTitle: String {
        turns.first(where: { $0.role == "user" })?.text.map {
            String($0.prefix(60))
        } ?? sessionId
    }

    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        switch turn.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(turn.text ?? "")
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.jarvisCard))
                    .foregroundStyle(.white)
            }
        case "assistant":
            VStack(alignment: .leading, spacing: 6) {
                // LLM text — prominent, plain, no bubble chrome.
                if let t = turn.text, !t.isEmpty {
                    Text(t)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                if turn.toolCount > 0 {
                    ToolActivityCard(turn: turn)
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Loading / projection

    @MainActor
    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            struct Page: Decodable {
                struct Pagination: Decodable { let returned: Int }
                let messages: [Message]
                let pagination: Pagination
            }
            let page = try await CCClient.shared.get(
                "/api/sessions/\(sessionId)/messages?order=oldest&limit=500",
                as: Page.self)
            turns = Self.project(page.messages)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Fold the raw message stream into display turns: consecutive tool
    /// results after an assistant message collapse into that assistant turn.
    static func project(_ messages: [Message]) -> [Turn] {
        var out: [Turn] = []
        for m in messages {
            switch m.role {
            case "user":
                let text = m.content ?? ""
                guard !text.isEmpty else { continue }
                out.append(Turn(id: "u\(m.id)", role: "user", text: text))
            case "assistant":
                var names: [String] = []
                if let tc = m.toolCalls, let data = tc.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for call in arr {
                        if let fn = call["function"] as? [String: Any],
                           let n = fn["name"] as? String {
                            names.append(n)
                        }
                    }
                }
                out.append(Turn(id: "a\(m.id)", role: "assistant",
                                text: m.content, toolCount: names.count,
                                toolNames: names))
            case "tool":
                // Attach to the most recent assistant turn, creating it if the
                // stream begins with tool output (compacted transcripts).
                let name = m.toolName ?? "tool"
                let detail = ToolDetail(
                    id: "t\(m.id)", name: name,
                    summary: Self.summarize(name, output: m.content ?? ""),
                    output: m.content ?? "")
                if out.last?.role == "assistant" {
                    out[out.count - 1].details.append(detail)
                    out[out.count - 1].toolCount = max(out[out.count - 1].toolCount, out[out.count - 1].details.count)
                } else {
                    var t = Turn(id: "a\(m.id)", role: "assistant", text: nil)
                    t.details = [detail]
                    t.toolCount = 1
                    t.toolNames = [name]
                    out.append(t)
                }
            default:
                break // session_meta and internal roles are not rendered
            }
        }
        return out
    }

    /// One-line tool summary: the most human-useful fragment of the call.
    static func summarize(_ name: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1)[0]
        let line = String(firstLine)
        return line.count > 80 ? String(line.prefix(77)) + "…" : line
    }
}

/// The collapsed "N tool activities" pill, expandable to a per-call list.
struct ToolActivityCard: View {
    let turn: TranscriptView.Turn
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                    Image(systemName: "hammer.fill").font(.caption)
                    Text(turn.toolCount == 1
                         ? "1 tool activity — \(turn.toolNames.first ?? "tool")"
                         : "\(turn.toolCount) tool activities")
                        .font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.jarvisCard.opacity(0.6)))
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(turn.details) { d in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.name).font(.caption.bold())
                        Text(d.summary).font(.caption2).foregroundStyle(.secondary)
                        Text(d.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.jarvisCard.opacity(0.4)))
                }
            }
        }
    }
}
