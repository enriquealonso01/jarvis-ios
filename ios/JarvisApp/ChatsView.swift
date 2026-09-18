import SwiftUI

/// Chats tab: per-project threads (from the CC dispatch board / knowledge map),
/// each backed by the dashboard agent conversation endpoints.
/// Phase 3: ad-hoc "New chat" row → /api/control/project/task threads
/// (project-<slug> conversations, server-side contract verified live), pull
/// thread items into the subtitle, and a pinned "New task" composer.
struct ProjectsView: View {
    @State private var threads: [ThreadRow] = []
    @State private var error: String?
    @State private var loading = false
    @State private var showNewTask = false

    struct ThreadRow: Identifiable {
        let id: String
        let title: String
        let project: String
        let openCount: Int
        let lastMessage: String
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button {
                    Haptics.tap()
                    showNewTask = true
                } label: {
                    Label("New project task…", systemImage: "square.and.pencil")
                        .foregroundStyle(Color.jarvisAccent)
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
                            if !t.lastMessage.isEmpty {
                                Text(t.lastMessage).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
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
            .sheet(isPresented: $showNewTask) {
                NewTaskSheet { project, text in
                    await startTask(project: project, text: text)
                }
            }
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
                    let items: [Item]?
                }
                struct Item: Decodable {
                    let message: String?
                    let ago_seconds: Int?
                }
                let threads: [Thread]?
            }
            let board: Board = try await CCClient.shared.get("/api/control/dispatch/board", as: Board.self)
            threads = (board.threads ?? []).map { t in
                let last = (t.items ?? []).first
                return ThreadRow(id: "work-\(t.slug)",
                                 title: t.title,
                                 project: t.project ?? "",
                                 openCount: t.open_count ?? 0,
                                 lastMessage: last?.message ?? "")
            }
            error = nil
        } catch {
            self.error = "Can't load threads."
        }
    }

    /// POST /api/control/project/task — starts a per-project thread
    /// (conversation id `project-<slug>` server-side). Opens the thread.
    @MainActor
    private func startTask(project: String, text: String) async {
        do {
            struct TaskReply: Decodable { let reply: String }
            let _: TaskReply = try await CCClient.shared.post(
                "/api/control/project/task",
                body: ["project": project, "text": text],
                as: TaskReply.self)
            let slug = project.map { $0.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "") } ?? ""
            let id = "project-" + (slug.isEmpty ? "adhoc" : String(slug.prefix(48)))
            Haptics.success()
            showNewTask = false
            threads.insert(ThreadRow(id: id, title: text, project: project, openCount: 1, lastMessage: ""), at: 0)
        } catch {
            Haptics.error()
        }
    }
}

/// Composer for the "New project task" flow: project name + instruction.
struct NewTaskSheet: View {
    var onStart: (String, String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var project = ""
    @State private var text = ""
    @State private var starting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("e.g. jarvis-ios", text: $project)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Task for JARVIS") {
                    TextField("What should JARVIS do?", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start") {
                            starting = true
                            Task {
                                await onStart(project.trimmingCharacters(in: .whitespaces),
                                              text.trimmingCharacters(in: .whitespaces))
                                starting = false
                            }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }
}

/// A chat thread with JARVIS about a work item (or an ad-hoc conversation).
/// Send → POST /api/control/work/{id}/chat (dashboard agent), optimistic UI.
/// `workId` may be `work-<slug>` (dispatch board), `project-<slug>` (per-project
/// task thread) — the server's history resolver matches by exact, prefix, then
/// substring session id, and chat accepts any work id.
struct WorkThreadView: View {
    let workId: String
    let title: String

    struct ChatLine: Identifiable, Equatable {
        let id = UUID()
        let role: String   // "user" | "assistant" | "tool"
        let text: String
    }

    @State private var lines: [ChatLine] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var lastError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty && !sending {
                        Text("No messages yet — say something to JARVIS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(lines) { line in
                        bubble(line)
                    }
                    if sending {
                        HStack(spacing: 8) {
                            ProgressView().tint(Color.jarvisAccent)
                            Text("JARVIS is thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
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
            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
            }
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHistory() }
        // Backlog #2: poll history so agent replies that land after a slow
        // turn (or sent from another surface) appear without reopening.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !sending { await pollHistory() }
            }
        }
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
        // work-<slug> / project-<slug> map to session ids server-side; the
        // dashboard resolves exact → prefix → substring. Ad-hoc ids start empty.
        var id = workId
        for prefix in ["work-", "project-"] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count))
        }
        do {
            let hist: WorkHistory = try await CCClient.shared.get(
                "/api/control/work/\(id)/history", as: WorkHistory.self
            )
            lines = Self.decodedLines(hist)
            lastError = nil
        } catch {
            // leave empty — send still works (dashboard keeps its own thread)
        }
    }

    /// Silent poll tick: refresh from the server thread, keep scroll anchor,
    /// never surface transient errors from a background poll.
    @MainActor
    private func pollHistory() async {
        var id = workId
        for prefix in ["work-", "project-"] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count))
        }
        guard let hist = try? await CCClient.shared.get(
            "/api/control/work/\(id)/history", as: WorkHistory.self
        ) else { return }
        let fresh = Self.decodedLines(hist)
        if fresh != lines { lines = fresh }
    }

    private static func decodedLines(_ hist: WorkHistory) -> [ChatLine] {
        (hist.messages ?? [])
            .filter { $0.role == "user" || $0.role == "assistant" }
            .compactMap { m in
                guard let text = m.text, !text.isEmpty else { return nil }
                return ChatLine(role: m.role, text: text)
            }
    }

    @MainActor
    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        sending = true
        do {
            let reply: WorkChatReply = try await CCClient.shared.post(
                "/api/control/work/\(workId)/chat",
                body: ["text": text, "title": title],
                as: WorkChatReply.self
            )
            // The server thread is the source of truth — reload instead of
            // appending locally so timestamps/tool turns line up and the
            // poller never fights an optimistic bubble.
            if reply.reply.isEmpty {
                await loadHistory()
            } else {
                lines.append(ChatLine(role: "user", text: text))
                lines.append(ChatLine(role: "assistant", text: reply.reply))
            }
            lastError = nil
            Haptics.tap()
        } catch {
            // Send failed: restore the draft so nothing is silently lost.
            draft = text
            lastError = "Message didn't send — check connection and try again."
            Haptics.error()
        }
        sending = false
    }
}
