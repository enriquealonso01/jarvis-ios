import SwiftUI
import DesignSystem
import Persistence

/// The sidebar panel contents, top-to-bottom exactly per UI Law §1:
///   profile row → Settings sheet; New chat + Search; horizontal add-ons bar
///   (Agent Runs · Recordings · Memory · Schedules); Pinned (chats +
///   projects mixed); Projects (expandable/collapsible, Project Home from
///   the row); Recents (combined chronological, groupable by project).
public struct SidebarPanel: View {
    @Bindable var model: SidebarViewModel
    /// Selection plumbing owned by the host app (which screen to push).
    @Binding var selection: SidebarSelection
    /// App-provided Settings sheet contents (profile row → Settings, UI Law §1).
    var settingsSheet: AnyView? = nil
    @State private var settingsPresented = false
    @Environment(\.dismiss) private var dismiss

    public init(
        model: SidebarViewModel,
        selection: Binding<SidebarSelection>,
        settingsSheet: AnyView? = nil
    ) {
        self.model = model
        self._selection = selection
        self.settingsSheet = settingsSheet
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileRow

            newChatAndSearch

            AddOnsBar(selection: $selection)

            Divider()
                .padding(.vertical, Tokens.Spacing.s)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    PinnedSection(entries: model.pinnedEntries) { entry in
                        switch entry.kind {
                        case .chat(let id): selection = .chat(id: id)
                        case .project(let id): selection = .projectHome(id: id)
                        }
                        dismiss()
                    }
                    ProjectsSection(
                        groups: model.projectGroups,
                        expanded: model.expandedProjects
                    ) { projectID in
                        withAnimation {
                            if model.expandedProjects.contains(projectID) {
                                model.expandedProjects.remove(projectID)
                            } else {
                                model.expandedProjects.insert(projectID)
                            }
                        }
                    } onProjectHome: { project in
                        selection = .projectHome(id: project.id)
                        dismiss()
                    } onChat: { conversation in
                        selection = .chat(id: conversation.id)
                        dismiss()
                    }
                    RecentsSection(
                        groups: model.recentsGroupedByProject,
                        flat: model.recentChats
                    ) { conversation in
                        selection = .chat(id: conversation.id)
                        dismiss()
                    }
                }
                .padding(.horizontal, Tokens.Spacing.l)
                .padding(.bottom, Tokens.Spacing.xl)
            }
        }
        .sheet(isPresented: $settingsPresented) {
            NavigationStack { settingsSheet ?? AnyView(SettingsHostView()) }
        }
        .task { await model.load() }
    }

    // MARK: - Profile row (→ Settings sheet)

    private var profileRow: some View {
        Button {
            settingsPresented = true
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS")
                        .font(.headline)
                    Text("Settings")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.top, Tokens.Spacing.l)
        .padding(.bottom, Tokens.Spacing.m)
        .accessibilityIdentifier("sidebar.profileRow")
    }

    // MARK: - New chat + Search

    private var newChatAndSearch: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Button {
                selection = .newChat
                dismiss()
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, Tokens.Spacing.m)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("sidebar.newChat")

            Button {
                selection = .search
                dismiss()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, Tokens.Spacing.m)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("sidebar.search")
        }
        .padding(.horizontal, Tokens.Spacing.l)
    }
}

private extension Tokens {
    // Local extra spacing not worth a token.
    static let xl: CGFloat = 24
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
}
