import Foundation
import Persistence

/// Everything the Item 3 sidebar needs, straight from the Item 1 store.
/// Sendable struct snapshots crossing actor isolation — the sidebar never
/// touches GRDB rows directly (plan §5.1: UI on `Stored*` only).
public struct SidebarEntry: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case chat(id: UUID)
        case project(id: UUID)
    }

    public let kind: Kind
    public let title: String
    /// Chat subtitle (last-message preview); projects have none.
    public let subtitle: String?
    /// Chat update / project update timestamp — the Recents sort key.
    public let updatedAt: Date

    public var id: Kind { kind }

    public init(kind: Kind, title: String, subtitle: String? = nil, updatedAt: Date) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.updatedAt = updatedAt
    }
}

/// A project row in the Projects section with its chats attached, so the
/// expandable DisclosureGroup renders Project Home + project chats from one
/// snapshot (no per-row store round-trips).
public struct SidebarProjectGroup: Identifiable, Equatable, Sendable {
    public let project: StoredProject
    /// Project chats, newest first.
    public let conversations: [StoredConversation]

    public var id: UUID { project.id }
    /// Pinned projects sort to the top of the Projects section.
    public var isPinned: Bool { project.pinned }

    public init(project: StoredProject, conversations: [StoredConversation]) {
        self.project = project
        self.conversations = conversations
    }
}

/// Recents grouped by project (UI Law §1: "combined chronological list,
/// groupable by project"). Ordering within a group is newest-first; the
/// groups themselves keep the recents order of each group's newest chat.
public struct SidebarRecentsGroup: Identifiable, Equatable, Sendable {
    /// nil = ungrouped chats.
    public let projectID: UUID?
    public let projectName: String?
    public let conversations: [StoredConversation]

    public var id: UUID? { projectID }

    public init(projectID: UUID?, projectName: String? = nil, conversations: [StoredConversation]) {
        self.projectID = projectID
        self.projectName = projectName
        self.conversations = conversations
    }
}

/// The horizontal add-ons bar (UI Law §1) — the slot ChatGPT uses for
/// Images / Codex / Pulse. Agent Runs is live from day one (runs are
/// persisted since Item 1); the other three are placeholder destinations
/// that navigate to empty list screens until their milestone items land.
public struct SidebarAddOn: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }

    /// Bar contents top-to-bottom order (left-to-right on screen).
    public static let standard: [SidebarAddOn] = [
        SidebarAddOn(id: "runs", title: "Agent Runs", systemImage: "arrow.triangle.branch"),
        SidebarAddOn(id: "recordings", title: "Recordings", systemImage: "waveform"),
        SidebarAddOn(id: "memory", title: "Memory", systemImage: "brain.head.profile"),
        SidebarAddOn(id: "schedules", title: "Schedules", systemImage: "calendar.badge.clock"),
    ]
}
