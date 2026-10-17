import Foundation

/// What the host app should show after a sidebar action. The package never
/// navigates itself — it reports intent; the app shell (ios/JarvisApp)
/// resolves it against its own screens.
public enum SidebarSelection: Equatable, Sendable {
    case chat(id: UUID)
    case projectHome(id: UUID)
    case newChat
    case search
    case addOn(SidebarAddOnID)
}

/// Stable identifiers for the add-ons bar destinations.
public enum SidebarAddOnID: String, Equatable, Sendable, CaseIterable {
    case runs
    case recordings
    case memory
    case schedules
}
