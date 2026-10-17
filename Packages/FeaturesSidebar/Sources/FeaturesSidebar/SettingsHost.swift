import SwiftUI

/// Placeholder Settings host inside the package. The app shell passes its
/// own sheet contents via `SidebarHost.settingsSheet`; this view is only the
/// fallback so the panel compiles and previews standalone.
struct SettingsHostView: View {
    var body: some View {
        Text("Settings")
            .navigationTitle("Settings")
    }
}
