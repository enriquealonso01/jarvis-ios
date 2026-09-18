import SwiftUI

/// Chats tab: per-project threads (from the CC knowledge map / dispatch board),
/// each backed by the dashboard agent conversation endpoints.
struct ProjectsView: View {
    @State private var threads: [ThreadRow] = []
    @State private var error: String?
    @State private var loading = false

    struct ThreadRow: Identifiable {
        let id: String
        let title: String
        let project: String
        let openCount: Int
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ForEach(threads) { t in
                    NavigationLink {
                        WorkThreadView(workId: t.id, title: t.title)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.title).lineLimit(1)
                                Spacer()
                                if t.openCount > 0 {
                                    Text("\(t.openCount)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.jarvisAccent.opacity(0.25)))
                                }
                            }
                            if !t.project.isEmpty {
                                Text(t.project).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if threads.isEmpty && error == nil && !loading {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No open threads.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
                if let error {
                    VStack(spacing: 10) {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Haptics.tap()
                            Task { await load() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Chats")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            struct Board: Decodable {
                struct Thread: Decodable {
                    let slug: String
                    let title: String
                    let project: String?
                    let open_count: Int?
                }
                let threads: [Thread]?
            }
            let board: Board = try await CCClient.shared.get("/api/control/dispatch/board", as: Board.self)
            threads = (board.threads ?? []).map {
                ThreadRow(id: "work-\($0.slug)", title: $0.title, project: $0.project ?? "", openCount: $0.open_count ?? 0)
            }
            error = nil
        } catch {
            self.error = "Can't load threads."
        }
    }
}

/// A chat thread with JARVIS about a work item (or an ad-hoc conversation).
/// Send → POST /api/control/work/{id}/chat (dashboard agent), optimistic UI.
struct WorkThreadView: View {
    let workId: String
    let title: String

    struct ChatLine: Identifiable {
        let id = UUID()
        let role: String   // "user" | "assistant" | "tool"
        let text: String
    }

    @State private var lines: [ChatLine] = []
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(lines) { line in
                        bubble(line)
                    }
                }
                .padding(14)
            }
            HStack(spacing: 10) {
                TextField("Message JARVIS…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHistory() }
    }

    private func bubble(_ line: ChatLine) -> some View {
        HStack {
            if line.role == "user" { Spacer(minLength: 40) }
            Text(line.text)
                .font(.subheadline)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(line.role == "user" ? Color.jarvisAccent.opacity(0.22) : Color.jarvisCard)
                )
                .foregroundStyle(.primary)
            if line.role != "user" { Spacer(minLength: 40) }
        }
    }

    @MainActor
    private func loadHistory() async {
        // work-<slug> threads map to dispatch-board items; the dashboard
        // exposes history per session/work id. Ad-hoc ids start empty.
        let id = workId.hasPrefix("work-") ? String(workId.dropFirst(5)) : workId
        do {
            let hist: WorkHistory = try await CCClient.shared.get(
                "/api/control/work/\(id)/history", as: WorkHistory.self
            )
            lines = (hist.messages ?? [])
                .filter { $0.role == "user" || $0.role == "assistant" }
                .compactMap { m in
                    guard let text = m.text, !text.isEmpty else { return nil }
                    return ChatLine(role: m.role, text: text)
                }
        } catch {
            // leave empty — send still works (dashboard keeps its own thread)
        }
    }

    @MainActor
    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        lines.append(ChatLine(role: "user", text: text))
        draft = ""
        sending = true
        do {
            let reply: WorkChatReply = try await CCClient.shared.post(
                "/api/control/work/\(workId)/chat",
                body: ["text": text, "title": title],
                as: WorkChatReply.self
            )
            lines.append(ChatLine(role: "assistant", text: reply.reply))
        } catch {
            lines.append(ChatLine(role: "assistant", text: "(couldn't reach JARVIS — try again)"))
        }
        sending = false
    }
}
