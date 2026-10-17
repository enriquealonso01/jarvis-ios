import SwiftUI

/// Projects tab: read-only list of Enrique's projects from the dashboard's
/// control-center API (GET /api/control/projects — same Bearer-auth'd
/// CCClient every other tab uses; the endpoint was verified live:
/// {generated_at, bridge:{reachable}, roots:[…], projects:[{id, name, domain,
/// source, path, kind, summary, caution, restricted, detected, last_seen_at}]}).
/// Local quick notes ride on top: per-project free text in UserDefaults,
/// keyed by the server's stable project id.
struct ProjectsManagerView: View {
    /// Server project shape — flexible optional fields on purpose: the
    /// dashboard's project dicts come from two sources (pc_bridge scan and
    /// the static system entry) and differ in which keys they carry.
    struct Project: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let domain: String?
        let source: String?
        let path: String?
        let kind: String?
        let summary: String?
        let caution: String?
        let restricted: Bool?
    }

    struct Payload: Decodable {
        let projects: [Project]?
    }

    /// Local quick note for one project (UserDefaults-backed).
    struct Note: Codable, Identifiable, Equatable {
        let projectId: String
        var text: String
        var updatedAt: Date
        var id: String { projectId }
    }

    enum LoadState: Equatable {
        case loading
        case loaded
        /// Distinguishing empty-success from failure is the same contract as
        /// CallsView/SecretsView: a transient outage must NEVER render as
        /// "no projects".
        case failed(String)
    }

    @State private var projects: [Project] = []
    @State private var state: LoadState = .loading
    @State private var notes: [String: Note] = [:]
    @State private var noteDraftProject: Project?

    private static let notesKey = "jarvis.projects.notes.v1"

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Loading projects…")
                case .failed(let why):
                    errorView(why)
                case .loaded:
                    if projects.isEmpty {
                        emptyView
                    } else {
                        projectList
                    }
                }
            }
            .navigationTitle("Projects")
            .refreshable { await load() }
            .task { if projects.isEmpty { await load() } }
            .sheet(item: $noteDraftProject) { project in
                NoteSheet(project: project, note: notes[project.id]) { text in
                    saveNote(projectId: project.id, text: text)
                }
            }
        }
    }

    // MARK: - Views

    private var projectList: some View {
        List {
            ForEach(projects) { project in
                NavigationLink {
                    ProjectDetailView(project: project,
                                      note: notes[project.id],
                                      onSaveNote: { text in saveNote(projectId: project.id, text: text) })
                } label: {
                    ProjectRow(project: project, hasNote: notes[project.id] != nil)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No projects discovered")
                .font(.headline)
            Text("The dashboard found no project workspaces. If the PC bridge is offline, its scan finds nothing — check the dashboard's Control Center.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .padding(.top, 60)
    }

    private func errorView(_ why: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text("Couldn't load projects")
                .font(.headline)
            Text(why)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }

    // MARK: - Data

    @MainActor
    private func load() async {
        state = .loading
        do {
            let payload = try await CCClient.shared.get("/api/control/projects", as: Payload.self)
            // Sort by (domain, name) — "zzz" sentinel pushes unknown domains last.
            projects = (payload.projects ?? []).sorted {
                let d0 = $0.domain ?? "zzz", d1 = $1.domain ?? "zzz"
                return d0 == d1 ? $0.name < $1.name : d0 < d1
            }
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
        loadNotes()
    }

    // MARK: - Notes (local quick notes, UserDefaults)

    private func saveNote(projectId: String, text: String) {
        var updated = notes
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            updated.removeValue(forKey: projectId)
        } else {
            updated[projectId] = Note(projectId: projectId, text: trimmed, updatedAt: Date())
        }
        notes = updated
        persistNotes()
        Haptics.tap()
    }

    private func loadNotes() {
        guard let data = UserDefaults.standard.data(forKey: Self.notesKey),
              let dict = try? JSONDecoder().decode([String: Note].self, from: data) else { return }
        notes = dict
    }

    private func persistNotes() {
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: Self.notesKey)
        }
    }
}

// MARK: - Row + detail

private struct ProjectRow: View {
    let project: ProjectsManagerView.Project
    let hasNote: Bool

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .frame(width: 26)
                .foregroundStyle(Color.jarvisAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                HStack(spacing: 5) {
                    Text(project.domain ?? "project")
                    if let kind = project.kind, !kind.isEmpty {
                        Text("· \(kind)")
                    }
                    if hasNote {
                        Image(systemName: "note.text")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            statusDot
        }
    }

    /// caution → status semantics: high/normal map to the dot color the same
    /// way the dashboard's Control Center renders them.
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch (project.caution ?? "normal").lowercased() {
        case "high": return .red
        case "restricted": return .orange
        default: return .green
        }
    }

    private var iconName: String {
        switch project.kind {
        case "repo": return "externaldrive.badge.icloud"
        case "workspace": return "shippingbox.fill"
        default: return "folder.fill"
        }
    }
}

private struct ProjectDetailView: View {
    let project: ProjectsManagerView.Project
    let note: ProjectsManagerView.Note?
    let onSaveNote: (String) -> Void
    @State private var draft: String

    init(project: ProjectsManagerView.Project, note: ProjectsManagerView.Note?, onSaveNote: @escaping (String) -> Void) {
        self.project = project
        self.note = note
        self.onSaveNote = onSaveNote
        _draft = State(initialValue: note?.text ?? "")
    }

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Name", value: project.name)
                if let domain = project.domain {
                    LabeledContent("Domain", value: domain)
                }
                if let kind = project.kind {
                    LabeledContent("Kind", value: kind)
                }
                if let source = project.source {
                    LabeledContent("Source", value: source)
                }
                if let caution = project.caution {
                    LabeledContent("Caution", value: caution)
                }
            }
            if let summary = project.summary, !summary.isEmpty {
                Section("Summary") {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let path = project.path, !path.isEmpty {
                Section("Path") {
                    Text(path)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
            Section {
                TextField("Quick note — what's next on this project?", text: $draft, axis: .vertical)
                    .lineLimit(3...8)
                Button("Save note") {
                    onSaveNote(draft)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    == (note?.text ?? ""))
                if let note {
                    LabeledContent("Last saved",
                                   value: note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Quick note (local to this phone)")
            } footer: {
                Text("Notes never leave the device — handy one-liners while you're out.")
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
