import SwiftUI
import DesignSystem
import Persistence

/// Pinned section: chats + projects mixed (UI Law §1).
struct PinnedSection: View {
    let entries: [SidebarEntry]
    let onSelect: (SidebarEntry) -> Void

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                sectionHeader("Pinned", systemImage: "pin.fill")
                ForEach(entries) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        row(for: entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.pinned.\(entry.title)")
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: SidebarEntry) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            let isProject: Bool = {
                if case .project = entry.kind { return true }
                return false
            }()
            Image(systemName: isProject ? "folder.fill" : "bubble.left.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Projects section: expandable/collapsible rows with Project Home as the
/// first entry of the expanded contents (UI Law §1).
struct ProjectsSection: View {
    let groups: [SidebarProjectGroup]
    let expanded: Set<UUID>
    let onToggleExpanded: (UUID) -> Void
    let onProjectHome: (StoredProject) -> Void
    let onChat: (StoredConversation) -> Void

    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                sectionHeader("Projects", systemImage: "folder.fill")
                ForEach(groups) { group in
                    let projectID = group.project.id
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { expanded.contains(projectID) },
                            set: { _ in onToggleExpanded(projectID) }
                        )
                    ) {
                        ProjectHomeRow(project: group.project, onProjectHome: onProjectHome)
                        ForEach(group.conversations) { conversation in
                            Button {
                                onChat(conversation)
                            } label: {
                                chatRow(conversation)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sidebar.projectChat.\(conversation.id.uuidString)")
                        }
                    } label: {
                        HStack(spacing: Tokens.Spacing.m) {
                            Image(systemName: "folder.fill")
                                .font(.footnote)
                                .foregroundStyle(group.isPinned ? Color.accentColor : .secondary)
                                .frame(width: 20)
                            Text(group.project.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("sidebar.project.\(group.project.name)")
                }
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ conversation: StoredConversation) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            Color.clear
                .frame(width: 20, height: 1)
            Image(systemName: "bubble.left.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            Text(conversation.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// "Project Home" entry rendered as the first row of an expanded project.
struct ProjectHomeRow: View {
    let project: StoredProject
    let onProjectHome: (StoredProject) -> Void

    var body: some View {
        Button {
            onProjectHome(project)
        } label: {
            HStack(spacing: Tokens.Spacing.m) {
                Color.clear
                    .frame(width: 20, height: 1)
                Image(systemName: "house.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text("Project Home")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.projectHome.\(project.name)")
    }
}

/// Recents: combined chronological, groupable by project (UI Law §1).
struct RecentsSection: View {
    /// Grouped form (projectID nil = ungrouped). Empty when grouping is off.
    let groups: [SidebarRecentsGroup]
    /// Flat chronological list — used when groups carry a single ungrouped
    /// bucket (no grouping possible), and for the grouped=true header count.
    let flat: [StoredConversation]
    let onSelect: (StoredConversation) -> Void

    init(
        groups: [SidebarRecentsGroup],
        flat: [StoredConversation],
        onSelect: @escaping (StoredConversation) -> Void
    ) {
        self.groups = groups
        self.flat = flat
        self.onSelect = onSelect
    }

    var body: some View {
        if !flat.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                sectionHeader("Recents", systemImage: "clock")
                ForEach(groups.isEmpty ? [SidebarRecentsGroup(projectID: nil, conversations: flat)] : groups) { group in
                    if let name = group.projectName {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, Tokens.Spacing.xs)
                    }
                    ForEach(group.conversations) { conversation in
                        Button {
                            onSelect(conversation)
                        } label: {
                            HStack(spacing: Tokens.Spacing.m) {
                                Image(systemName: "bubble.left.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(conversation.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    if let preview = conversation.lastMessagePreview {
                                        Text(preview)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar.recent.\(conversation.id.uuidString)")
                    }
                }
            }
        }
    }
}

@ViewBuilder
private func sectionHeader(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.top, Tokens.Spacing.xs)
}
