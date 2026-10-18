import Foundation
import SwiftUI
import Persistence
import DesignSystem

// MARK: - Item 10: Project Home (UI-Expansion package §05 "Projects")
//
// Project detail surface: project title, instructions, sources, the
// project's recent chats, New project chat (package §03: "Project detail
// shows project title, description, instructions, sources/attachments,
// recent project chats, New project chat").
//
// ISOLATION LAW (QA-pinned): every conversation query is filtered by
// `conversation.projectID == project.id` at the STORE layer
// (PersistenceStore.conversations(projectID:)); the view model recomposes
// the same rule through the pure `ProjectScope` contract. A chat of
// project A can never appear in project B's Home — the queries are scoped
// by construction, not by post-filtering the global lists.

/// One Project Home section row the view renders.
public struct ProjectHomeSection: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case instructions
        case sources
        case chats
    }

    public let kind: Kind
    public let title: String
    public let systemImage: String

    public var id: String { "\(kind)" }

    public init(kind: Kind, title: String, systemImage: String) {
        self.kind = kind
        self.title = title
        self.systemImage = systemImage
    }

    /// §05 UX: identity first, then Sources, Instructions, Chats.
    public static let standard: [ProjectHomeSection] = [
        ProjectHomeSection(kind: .sources, title: "Sources", systemImage: "doc.text"),
        ProjectHomeSection(kind: .instructions, title: "Instructions", systemImage: "text.alignleft"),
        ProjectHomeSection(kind: .chats, title: "Chats", systemImage: "bubble.left"),
    ]
}

/// A delete/side-effect report from the view model (QA asserts on these).
public enum ProjectHomeEvent: Sendable, Equatable {
    case instructionsSaved(characterCount: Int)
    case sourceAdded(name: String)
    case sourceRemoved(id: UUID)
    case renameRejected
    /// newChat refused: the project row is gone (deleted mid-session).
    case newChatUnavailable
}

/// Store-backed Project Home view model. All I/O through the Item-1 store
/// actor; every read is project-scoped (see file header).
@MainActor
public final class ProjectHomeViewModel: ObservableObject {

    // MARK: Published state (the view renders only these)

    @Published public private(set) var project: StoredProject?
    /// The project's chats — ONLY this project's, newest first.
    @Published public private(set) var chats: [StoredConversation] = []
    /// The project's sources in display order.
    @Published public private(set) var sources: [StoredProjectSource] = []
    /// True once the first load completed (empty vs. missing project).
    @Published public private(set) var loaded = false

    /// Last side effect (QA observation point).
    @Published public private(set) var lastEvent: ProjectHomeEvent?

    // MARK: Identity + dependencies

    public let projectID: UUID
    private let store: PersistenceStore
    /// Set by the app shell when it can start chats (nil in headless tests).
    public var onNewChat: ((UUID) -> Void)?

    public init(projectID: UUID, store: PersistenceStore) {
        self.projectID = projectID
        self.store = store
    }

    // MARK: Loading (project-scoped reads only)

    /// Reload everything Project Home shows. The conversation query is the
    /// store's `project_id == id AND archived == false` read — the scoped
    /// source of truth. Never loads the global conversation list.
    public func load() async {
        project = await store.getProject(id: projectID)
        let scopedChats = await store.conversations(projectID: projectID)
        let scopedSources = await store.projectSources(projectID: projectID)
        // Belt-and-braces: compose the pure contract on the way out. The
        // store query already filtered; ProjectScope.filter is the pinned
        // isolation function every surface must route through.
        chats = ProjectScope.filter(scopedChats, to: projectID)
        sources = scopedSources
        loaded = true
    }

    // MARK: New project chat

    /// UI Law §1 "New chat" inside a project: creates a conversation row
    /// CARRYING `projectID` — the born-scoped chat is the isolation
    /// guarantee for everything it later streams. Refuses when the project
    /// row is gone (deleted mid-session) — surfaced, never a fake success.
    @discardableResult
    public func newChatTapped() async -> StoredConversation? {
        guard project != nil else {
            lastEvent = .newChatUnavailable
            return nil
        }
        let conversation = StoredConversation(
            projectID: projectID,
            title: "New chat",
            updatedAt: Date()
        )
        await store.upsert(conversation)
        await load()
        onNewChat?(conversation.id)
        return conversation
    }

    // MARK: Instructions (project-scoped, stored verbatim)

    /// Save instructions from the editor. Returns true on write; a missing
    /// project row refuses (never writes to a phantom id).
    @discardableResult
    public func saveInstructions(_ text: String) async -> Bool {
        let ok = await store.setProjectInstructions(id: projectID, to: text)
        if ok {
            await load()
            lastEvent = .instructionsSaved(
                characterCount: text.trimmingCharacters(in: .whitespacesAndNewlines).count)
        }
        return ok
    }

    // MARK: Sources

    /// Attach a source (file path or link). Refuses when the project row is
    /// gone — no orphan rows.
    @discardableResult
    public func addSource(kind: String, reference: String, name: String) async -> StoredProjectSource? {
        guard project != nil else { return nil }
        let source = await store.addProjectSource(StoredProjectSource(
            projectID: projectID,
            kind: kind,
            reference: reference,
            name: name
        ))
        if let source {
            await load()
            lastEvent = .sourceAdded(name: source.name)
        }
        return source
    }

    /// Remove one source. The store call is identity-scoped
    /// (`id AND project_id`) — a foreign id is a no-op, never a
    /// cross-project delete.
    public func removeSource(_ source: StoredProjectSource) async {
        let removed = await store.removeProjectSource(id: source.id, projectID: projectID)
        if removed {
            await load()
            lastEvent = .sourceRemoved(id: source.id)
        }
    }

    // MARK: Rename (project settings inline per §05 UX)

    /// Rename the project (whitespace-only rejected → `.renameRejected`).
    @discardableResult
    public func rename(to name: String) async -> Bool {
        let ok = await store.renameProject(id: projectID, to: name)
        if ok {
            await load()
        } else {
            lastEvent = .renameRejected
        }
        return ok
    }

    // MARK: Derived (pure; pinned headlessly)

    /// The header count line "N chats".
    public static func chatCountLine(count: Int) -> String {
        "\(count) chat\(count == 1 ? "" : "s")"
    }

    /// Truncated instructions preview for the collapsed section.
    public static func instructionsPreview(_ text: String, limit: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

// MARK: - The Project Home view (package §03 project detail)

/// Project detail: identity header, Sources, Instructions, Chats, New
/// project chat. Every list renders from the view model's scoped state.
public struct V2ProjectHomeView: View {
    @StateObject private var vm: ProjectHomeViewModel
    @State private var instructionsDraft = ""
    @State private var isEditingInstructions = false
    @State private var isAddingSource = false
    @State private var sourceName = ""
    @State private var sourceReference = ""
    @State private var renamePresented = false

    /// Opens a chat full-screen from Project Home (the shell's router).
    var onOpenChat: ((UUID) -> Void)? = nil

    public init(projectID: UUID, store: PersistenceStore,
                onOpenChat: ((UUID) -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ProjectHomeViewModel(
            projectID: projectID, store: store))
        self.onOpenChat = onOpenChat
    }

    public var body: some View {
        Group {
            if vm.loaded && vm.project == nil {
                // Deleted mid-session: honest empty state, never a phantom page.
                Text("Project not found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                content
            }
        }
        .navigationTitle(vm.project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    renamePresented = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityIdentifier("projectHome.rename")
            }
        }
        .sheet(isPresented: $renamePresented) {
            V2ProjectRenameSheet(initialName: vm.project?.name ?? "") { newName in
                // Always close; a rejected rename is a no-op write, not a
                // stuck sheet (the list simply keeps the current name).
                Task {
                    _ = await vm.rename(to: newName)
                    renamePresented = false
                }
            } onCancel: {
                renamePresented = false
            }
        }
        .task { await vm.load() }
    }

    private var content: some View {
        List {
            Section {
                // New project chat — functional from day one (§05 UX:
                // Project detail -> New chat).
                Button {
                    Task { await vm.newChatTapped() }
                } label: {
                    Label("New project chat", systemImage: "square.and.pencil")
                        .font(.body.weight(.semibold))
                }
                .accessibilityIdentifier("projectHome.newChat")
            }

            sourcesSection
            instructionsSection
            chatsSection
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Sources

    @ViewBuilder
    private var sourcesSection: some View {
        Section("Sources") {
            ForEach(vm.sources) { source in
                HStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: source.kind == "link" ? "link" : "doc")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name.isEmpty ? source.reference : source.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(source.kind)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await vm.removeSource(source) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("projectHome.source.remove.\(source.id.uuidString)")
                }
            }
            .onDelete { offsets in
                let targets = offsets.map { vm.sources[$0] }
                Task {
                    for source in targets { await vm.removeSource(source) }
                }
            }

            if isAddingSource {
                TextField("Name", text: $sourceName)
                    .accessibilityIdentifier("projectHome.source.name")
                TextField("File path or link", text: $sourceReference)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("projectHome.source.reference")
                Button("Add source") {
                    let name = sourceName.trimmingCharacters(in: .whitespaces)
                    let reference = sourceReference.trimmingCharacters(in: .whitespaces)
                    guard !reference.isEmpty else { return }
                    let kind = reference.lowercased().hasPrefix("http") ? "link" : "file"
                    Task {
                        await vm.addSource(kind: kind, reference: reference, name: name)
                        sourceName = ""
                        sourceReference = ""
                        isAddingSource = false
                    }
                }
                .disabled(sourceReference.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("projectHome.source.add")
            } else {
                Button {
                    isAddingSource = true
                } label: {
                    Label("Add source", systemImage: "plus")
                }
                .accessibilityIdentifier("projectHome.source.new")
            }
        }
    }

    // MARK: Instructions

    private var instructionsSection: some View {
        Section("Instructions") {
            if isEditingInstructions {
                TextField("How should JARVIS work in this project?", text: $instructionsDraft, axis: .vertical)
                    .lineLimit(4...10)
                    .accessibilityIdentifier("projectHome.instructions.field")
                HStack {
                    Button("Cancel") {
                        instructionsDraft = vm.project?.instructions ?? ""
                        isEditingInstructions = false
                    }
                    Spacer()
                    Button("Save") {
                        let draft = instructionsDraft
                        Task {
                            if await vm.saveInstructions(draft) {
                                isEditingInstructions = false
                            }
                        }
                    }
                    .accessibilityIdentifier("projectHome.instructions.save")
                }
                .font(.subheadline.weight(.semibold))
            } else {
                Text(instructionsPreviewText)
                    .font(.subheadline)
                    .foregroundStyle(vm.project?.instructions.isEmpty == false ? .primary : .secondary)
                    .accessibilityIdentifier("projectHome.instructions.text")
                Button("Edit instructions") {
                    instructionsDraft = vm.project?.instructions ?? ""
                    isEditingInstructions = true
                }
                .accessibilityIdentifier("projectHome.instructions.edit")
            }
        }
    }

    private var instructionsPreviewText: String {
        let text = vm.project?.instructions ?? ""
        return text.isEmpty
            ? "No instructions yet."
            : ProjectHomeViewModel.instructionsPreview(text)
    }

    // MARK: Chats (project-scoped — the isolation surface)

    @ViewBuilder
    private var chatsSection: some View {
        Section {
            if vm.chats.isEmpty {
                Text("No chats in this project yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.chats) { chat in
                    Button {
                        onOpenChat?(chat.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if let preview = chat.lastMessagePreview, !preview.isEmpty {
                                Text(preview)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("projectHome.chat.\(chat.id.uuidString)")
                }
            }
        } header: {
            Text(ProjectHomeViewModel.chatCountLine(count: vm.chats.count))
        }
    }
}

/// Inline rename sheet (project settings stay inside Project Home, §05).
struct V2ProjectRenameSheet: View {
    let initialName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project name", text: $draft)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("projectHome.rename.field")
            }
            .navigationTitle("Rename project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        submit()
                    }
                    .accessibilityIdentifier("projectHome.rename.save")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            draft = initialName
            fieldFocused = true
        }
    }

    private func submit() {
        // The parent owns dismissal (its binding closes the sheet) — the
        // sheet never self-dismisses, so a rejected rename can't strand it.
        onSubmit(draft)
    }
}
