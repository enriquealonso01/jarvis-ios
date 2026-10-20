import SwiftUI
import SwiftData
import UIKit

/// Refreshes the session list when the app returns from the background, so
/// sessions started or finished elsewhere show without a pull. A return that
/// lands while a load is running, or before the initial load has finished, is
/// remembered and refreshed once the list is idle: that load may have started
/// before backgrounding and would otherwise leave stale rows. Repeated returns
/// coalesce to one refresh.
struct SessionListForegroundRefresh: Equatable {
    private(set) var isPending = false

    /// Called on a real background-to-active return. Returns true when the
    /// list should refresh now; otherwise the return waits for `consumeIfReady`.
    mutating func appReturned(didCompleteInitialLoad: Bool, isLoading: Bool) -> Bool {
        isPending = true
        return consumeIfReady(didCompleteInitialLoad: didCompleteInitialLoad, isLoading: isLoading)
    }

    /// Called when loading stops or the initial load completes. Returns true
    /// once for a remembered return, as soon as the list is free to refresh.
    mutating func consumeIfReady(didCompleteInitialLoad: Bool, isLoading: Bool) -> Bool {
        guard isPending, didCompleteInitialLoad, !isLoading else { return false }
        isPending = false
        return true
    }
}

/// Picks the screen for the archive Undo toast (#865). Each archive gets a
/// number from `archiveStarted` when it starts. Once the server confirms it,
/// `archiveConfirmed` returns the host for its toast, or nil for no toast:
/// - Replies can land out of order, so an older archive never replaces a newer
///   one's toast. A newer archive that showed no toast blocks nothing.
/// - The toast shows on the screen the row was swiped on, if the user is still
///   there. Otherwise it shows on the other session screen if that is showing,
///   or nowhere. Either way the session is in Archived.
struct SessionListArchiveToastRoute: Equatable {
    /// On iPhone the Scheduled screen covers the list; on iPad it fills the
    /// detail column beside the sidebar.
    enum Host: Equatable {
        case list
        case scheduled
    }

    /// The screen the current toast belongs to.
    private(set) var host = Host.list
    private var startedCount = 0
    private var newestShown = 0

    mutating func archiveStarted() -> Int {
        startedCount += 1
        return startedCount
    }

    mutating func archiveConfirmed(
        _ number: Int,
        swipedOn: Host,
        destination: SessionNavigationDestination?,
        isRegularWidth: Bool
    ) -> Host? {
        guard number > newestShown else { return nil }

        func isShowing(_ candidate: Host) -> Bool {
            switch candidate {
            case .list:
                return isRegularWidth || destination == nil
            case .scheduled:
                return destination == .utility(.scheduled)
            }
        }

        let otherHost: Host = swipedOn == .list ? .scheduled : .list
        guard let chosen = [swipedOn, otherHost].first(where: isShowing) else { return nil }
        newestShown = number
        host = chosen
        return chosen
    }
}

/// Orders the session list's cold-start load. Restore needs only the session
/// rows, so it runs as soon as they arrive and the pending deep link has
/// resolved; projects and the active profile load afterwards, side by side.
enum SessionListInitialLoad {
    @MainActor
    static func run(
        resolvePendingDeepLink: @escaping @MainActor () async -> Void,
        loadSessions: @escaping @MainActor () async -> Void,
        restoreSelection: @MainActor () -> Void,
        loadProjects: @escaping @MainActor () async -> Void,
        loadActiveProfile: @escaping @MainActor () async -> Void
    ) async {
        async let sessions: Void = loadSessions()
        await resolvePendingDeepLink()
        await sessions
        guard !Task.isCancelled else { return }
        restoreSelection()
        await loadProjectsAndActiveProfile(loadProjects: loadProjects, loadActiveProfile: loadActiveProfile)
    }

    /// Runs the two loads concurrently; neither depends on the other. Also used
    /// by every later refresh of the list.
    @MainActor
    static func loadProjectsAndActiveProfile(
        loadProjects: @escaping @MainActor () async -> Void,
        loadActiveProfile: @escaping @MainActor () async -> Void
    ) async {
        async let activeProfile: Void = loadActiveProfile()
        await loadProjects()
        await activeProfile
    }
}

/// Runs the return refresh that `SessionListDestinationReturn` and
/// `SessionListForegroundRefresh` request. It reloads the rows, then runs one
/// poll tick when the poll was paused while a destination covered the compact
/// list, so badges such as Approval do not stay as they were before the push
/// until the restarted poll's first tick.
enum SessionListReturnRefresh {
    @MainActor
    static func run(
        refreshSessions: @MainActor () async -> Void,
        monitorTaskID: @MainActor () -> ActiveSessionMonitorTaskID,
        refreshActiveRows: @MainActor (ActiveSessionMonitorTaskID) async -> Void
    ) async {
        await refreshSessions()
        guard !Task.isCancelled else { return }
        // Read after the reload so the tick uses the rows that are streaming now.
        let taskID = monitorTaskID()
        guard taskID.needsTickOnReturn else { return }
        await refreshActiveRows(taskID)
    }
}

/// Refreshes the session list whenever the user leaves one destination for
/// another, so a row reflects whatever just happened in the chat it opened
/// (a rename, a `/clear`, new messages). Driven from the `destination`
/// `onChange` in `SessionListView`.
enum SessionListDestinationReturn {
    static func run(
        from oldValue: SessionNavigationDestination?,
        to newValue: SessionNavigationDestination?,
        suppressEmptyPlaceholders: () -> Void,
        refreshSessions: () -> Void
    ) {
        // Nothing to refresh against before the first destination, and a
        // destination that re-emits itself has no new server state to adopt.
        guard let oldValue, oldValue != newValue else { return }
        // Replacing one pending new-chat route with another stays on the same
        // screen, so it is not a return.
        if case .newChat = oldValue, case .newChat = newValue { return }

        if case .newChat = oldValue {
            // Keep this synchronous so an empty Untitled placeholder cannot
            // flash during the navigation transition. The refresh then adopts
            // the server's latest metadata for a new chat that became
            // contentful.
            suppressEmptyPlaceholders()
        }
        refreshSessions()
    }
}

/// The home header's wordmark: the Orbital mark and JARVIS, tinted with the header color
/// (Jarvis Cyan by default). Static, so it never repaints.
struct HermesHeaderLogo: View {
    let selectedColor: Color

    var body: some View {
        HStack(spacing: 8) {
            OrbitalCoreView(state: .idle, isStatic: true)
                .frame(width: 30, height: 30)
            Text(verbatim: "JARVIS")
                .font(.system(size: 22, weight: .semibold))
                .tracking(5)
                .foregroundStyle(selectedColor)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "JARVIS"))
    }
}

/// A request from `ContentView` to open the New Chat composer. Carries whether voice
/// dictation should auto-start (the "New Chat with Voice" App Intent, #338) and an optional
/// profile name to pin the new session to (the "New Chat in <Profile>" App Intent, #339).
/// A fresh `id` each time so a repeat invocation re-triggers navigation even if the previous
/// value lingers.
struct NewChatRequest: Equatable {
    let id: UUID
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile; nil uses the server's
    /// active profile (the plain "+" / "New Chat" behavior).
    let profileName: String?

    init(autoStartsVoiceInput: Bool = false, profileName: String? = nil) {
        self.id = UUID()
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
    }
}

struct PendingNewChatRoute: Identifiable, Hashable {
    let id = UUID()
    let initialDraft: String
    let initialAttachments: [SharedAttachmentImport]
    /// When true, the composer auto-starts voice dictation on appear (#338).
    let autoStartsVoiceInput: Bool
    /// When set, the new session is created pinned to this profile (#339).
    let profileName: String?
    /// When set, the new session is created in this project (#875).
    let projectID: String?

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil,
        projectID: String? = nil
    ) {
        self.initialDraft = initialDraft
        self.initialAttachments = initialAttachments
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
        self.projectID = projectID
    }

    static func == (lhs: PendingNewChatRoute, rhs: PendingNewChatRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum SessionListUtilityDestination: Hashable, Identifiable {
    case settings
    /// Settings → Notifications on its own, for the chat's one-time offer (#863).
    case notificationSettings
    /// The direct-Hermes Bots inbox, shown while Bot Mode (beta) is on.
    case bots
    case tasks
    case skills
    case memory
    case insights
    /// Archived sessions screen (issue #17), also reachable from Settings.
    case archived
    case scheduled

    var id: Self { self }
}

/// Identity for the session list's active-row poll. SwiftUI restarts the poll
/// whenever this changes, and the poll runs only while `shouldPoll` holds.
/// On compact width a pushed chat or utility screen covers the list, so the
/// poll pauses until the user returns; `SessionListReturnRefresh` reloads the
/// rows and runs one tick then. Scheduled sessions shows live rows from the same view model,
/// so it keeps the poll running.
struct ActiveSessionMonitorTaskID: Hashable {
    /// Wait between polls. The open chat watches its own run over SSE, so the
    /// list only needs badges and the Working-to-done switch reasonably fresh.
    static let pollInterval: Duration = .seconds(3)

    let streamIDs: [String]
    let hasActiveRows: Bool
    let isViewingCachedData: Bool
    let isListVisible: Bool
    let isRegularWidth: Bool

    init(
        streamIDs: [String],
        hasActiveRows: Bool,
        isViewingCachedData: Bool,
        isRegularWidth: Bool,
        destination: SessionNavigationDestination?
    ) {
        self.streamIDs = streamIDs
        self.hasActiveRows = hasActiveRows
        self.isViewingCachedData = isViewingCachedData
        self.isRegularWidth = isRegularWidth
        isListVisible = isRegularWidth || destination == nil || destination == .utility(.scheduled)
    }

    var shouldPoll: Bool {
        hasActiveRows && isListVisible && !isViewingCachedData
    }

    /// Whether a return to the list needs an immediate tick. Only compact width
    /// pauses the poll; the regular-width sidebar keeps polling throughout.
    var needsTickOnReturn: Bool {
        shouldPoll && !isRegularWidth
    }
}

#Preview("Hermes Header Logo") {
    VStack(spacing: 16) {
        ForEach(HeaderLogoColor.presets.prefix(4)) { preset in
            HermesHeaderLogo(selectedColor: preset.color)
                .frame(width: 220)
        }
    }
    .padding(24)
    .background(Color.black)
    .preferredColorScheme(.dark)
}
