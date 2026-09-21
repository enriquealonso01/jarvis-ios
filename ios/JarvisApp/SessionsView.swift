import SwiftUI

/// Sessions-first home: every Hermes/JARVIS session, grouped by project
/// (the session's working directory) or by source when it has no cwd.
/// GET /api/sessions?order=recent — dashboard Bearer auth via CCClient.
struct SessionsView: View {
    @State private var sessions: [SessionRow] = []
    @State private var projects: [ProjectGroup] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var query = ""

    struct SessionRow: Identifiable, Decodable {
        let id: String
        let title: String?
        let source: String?
        let cwd: String?
        let messageCount: Int?
        let toolCallCount: Int?
        let startedAt: Double?
        let lastActive: Double?
        let isActive: Bool?
        let archived: Bool?
        let profile: String?

        enum CodingKeys: String, CodingKey {
            case id, title, source, cwd, profile, archived
            case messageCount = "message_count"
            case toolCallCount = "tool_call_count"
            case startedAt = "started_at"
            case lastActive = "last_active"
            case isActive = "is_active"
        }

        var heading: String {
            if let t = title, !t.isEmpty { return t }
            if let c = cwd { return (c as NSString).lastPathComponent }
            return id
        }

        var projectName: String {
            if let c = cwd, !c.isEmpty {
                // Last path component reads best; fall back to the full cwd.
                let last = (c as NSString).lastPathComponent
                return last.isEmpty ? c : last
            }
            let s = source ?? "other"
            return s.capitalized
        }
    }

    struct ProjectGroup: Identifiable {
        let id: String          // project name
        var sessions: [SessionRow]
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && sessions.isEmpty {
                    ProgressView("Loading sessions…")
                } else if let e = errorText, sessions.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load sessions", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(e)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else if filteredProjects.isEmpty {
                    ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right")
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .searchable(text: $query, prompt: "Filter sessions")
            .refreshable { await load() }
            .task { if sessions.isEmpty { await load() } }
        }
    }

    private var filteredProjects: [ProjectGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return projects }
        return projects.compactMap { g in
            let hits = g.sessions.filter {
                $0.heading.lowercased().contains(q) || $0.projectName.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : ProjectGroup(id: g.id, sessions: hits)
        }
    }

    private var sessionList: some View {
        List {
            ForEach(filteredProjects) { group in
                Section {
                    ForEach(group.sessions) { s in
                        NavigationLink(value: s.id) {
                          SessionRowView(row: s)
                        }
                    }
                } header: {
                    Text(group.id)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: String.self) { sid in
            TranscriptView(sessionId: sid)
        }
    }

    @MainActor
    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            struct Page: Decodable {
                let sessions: [SessionRow]
                let total: Int
            }
            let page = try await CCClient.shared.get(
                "/api/sessions?order=recent&limit=100", as: Page.self)
            sessions = page.sessions
            regroup()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func regroup() {
        var byProject: [String: [SessionRow]] = [:]
        var order: [String] = []
        for s in sessions {
            let p = s.projectName
            if byProject[p] == nil { order.append(p) }
            byProject[p, default: []].append(s)
        }
        projects = order
            .compactMap { p in
                guard let rows = byProject[p], !rows.isEmpty else { return nil }
                return ProjectGroup(id: p, sessions: rows)
            }
    }
}

private struct SessionRowView: View {
    let row: SessionsView.SessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.heading)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if row.isActive == true {
                    Circle().fill(.green).frame(width: 7, height: 7)
                }
            }
            HStack(spacing: 8) {
                if let src = row.source, !src.isEmpty {
                    Text(src).font(.caption2).foregroundStyle(.secondary)
                }
                if let n = row.messageCount {
                    Label("\(n)", systemImage: "text.bubble").font(.caption2)
                }
                if let t = row.toolCallCount, t > 0 {
                    Label("\(t)", systemImage: "wrench").font(.caption2)
                }
                Spacer()
                if let ts = row.lastActive ?? row.startedAt {
                    Text(Self.fmt(ts)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func fmt(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
}
