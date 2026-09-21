import SwiftUI

/// Sessions-first home: every Hermes/JARVIS session, grouped by project
/// (the session's working directory) or by source when it has no cwd.
/// GET /api/sessions?order=recent — dashboard Bearer auth via CCClient.
struct SessionsView: View {
    @State private var sessions: [SessionRow] = []
    @State private var projects: [ProjectGroup] = []
    @State private var cronRuns: [SessionRow] = []
    @State private var cronExpanded = false
    @State private var projectTags: [String: String] = [:]
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

        /// Cron-run sessions (`cron_<jobid>_<ts>` ids) render in their own
        /// collapsed section at the BOTTOM of the list — work first, cron last.
        var isCronRun: Bool { id.hasPrefix("cron_") }

        /// A "❌" prefix in the title marks a failed cron run (scheduler sets
        /// it on failure) — failures must stay visible in the collapsed section.
        var cronFailed: Bool { heading.hasPrefix("❌") || heading.contains("(FAILED)") }

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

    /// Cron section rows, respecting both the search filter and the
    /// collapsed-by-default state (failed runs always stay visible).
    private var visibleCronRuns: [SessionRow] {
        var rows = cronRuns
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            rows = rows.filter { $0.heading.lowercased().contains(q) }
        }
        if !cronExpanded {
            let failed = rows.filter { $0.cronFailed }
            let recent = rows.filter { !$0.cronFailed }.prefix(3)
            rows = failed + Array(recent)
        }
        return rows
    }

    private var shownCronCount: Int { visibleCronRuns.count }

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
                } else if filteredProjects.isEmpty && cronRuns.isEmpty {
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

    private var sessionList: some View {
        List {
            // Work sessions first, grouped by project…
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
            // …then cron-job runs LAST, in a collapsed-by-default section.
            // Failures (❌ in the run title) stay visible when collapsed.
            if !visibleCronRuns.isEmpty {
                Section {
                    ForEach(visibleCronRuns) { s in
                        NavigationLink(value: s.id) {
                            CronRunRow(row: s)
                        }
                    }
                } header: {
                    HStack {
                        Text("Cron Jobs")
                        Spacer()
                        Text(cronExpanded ? "\(cronRuns.count) runs" : "last \(shownCronCount) of \(cronRuns.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if cronRuns.count > shownCronCount {
                        Button("Show all \(cronRuns.count) cron runs") {
                            cronExpanded = true
                        }
                        .font(.caption)
                    } else if cronExpanded && shownCronCount < cronRuns.count {
                        Button("Show fewer") { cronExpanded = false }
                            .font(.caption)
                    }
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
            // Project tags (server-side naming agent): map session id -> real
            // project (ticketflipping, krendora, …). Best-effort — falls back
            // to cwd/source grouping when the fetch fails.
            struct ProjectsMeta: Decodable {
                let projects: [String: String]?
            }
            if let meta = try? await CCClient.shared.get(
                "/bridge/projects/meta", as: ProjectsMeta.self) {
                projectTags = meta.projects ?? [:]
            }
            regroup()
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func regroup() {
        // Cron-job runs go to their own LAST section; work sessions group by
        // project (cwd) and always come first.
        var byProject: [String: [SessionRow]] = [:]
        var order: [String] = []
        var cron: [SessionRow] = []
        for s in sessions {
            if s.isCronRun {
                cron.append(s)
                continue
            }
            let p = projectTags[s.id] ?? s.projectName
            if byProject[p] == nil { order.append(p) }
            byProject[p, default: []].append(s)
        }
        projects = order
            .compactMap { p -> ProjectGroup? in
                guard let rows = byProject[p], !rows.isEmpty else { return nil }
                return ProjectGroup(id: p, sessions: rows)
            }
        cronRuns = cron
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

/// Row for a cron-job run: job title + status glyph (✅/❌) instead of the
/// generic message-count metadata. Kept compact — these live in the collapsed
/// bottom section.
private struct CronRunRow: View {
    let row: SessionsView.SessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: row.cronFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(row.cronFailed ? .red : .green)
                    .font(.caption)
                Text(cleanTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }
            HStack {
                Text("cron run").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let ts = row.lastActive ?? row.startedAt {
                    Text(SessionsView.SessionRow.fmt(ts)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var cleanTitle: String {
        var t = row.heading
        if t.hasPrefix("❌") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return t
    }
}
