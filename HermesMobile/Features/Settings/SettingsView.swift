import SwiftUI

/// Settings' index (#1252): the configured servers, then one row per page. The Hermex pages
/// apply on this iPhone to every server; a server's own settings live on its page. Nothing
/// here waits on the network, so the index opens instantly.
struct SettingsView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    let onDefaultProfileSelected: (DefaultProfileSelection) -> Void

    init(
        authManager: AuthManager,
        server: URL,
        onDefaultProfileSelected: @escaping (DefaultProfileSelection) -> Void = { _ in }
    ) {
        self.authManager = authManager
        self.server = server
        self.onDefaultProfileSelected = onDefaultProfileSelected
    }

    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.system.rawValue
    /// Read from the Keychain on each appear, so it follows a change made on the page.
    @State private var isPushOn = false

    var body: some View {
        List {
            // JARVIS has one server (`JarvisServer`): its page holds the sign-in and sessions.
            if let account = authManager.activeServer {
                Section(String(localized: "Server")) {
                    NavigationLink {
                        SettingsServerPage(
                            authManager: authManager,
                            account: account,
                            onDefaultProfileSelected: onDefaultProfileSelected
                        )
                    } label: {
                        SettingsServerRow(account: account)
                    }
                }
            }

            Section {
                NavigationLink {
                    SettingsAppearancePage()
                } label: {
                    LabeledContent {
                        Text((AppTheme(rawValue: appThemeRawValue) ?? .system).title)
                    } label: {
                        SettingsLabel(title: String(localized: "Appearance"), systemImage: "circle.lefthalf.filled")
                    }
                }

                NavigationLink {
                    SettingsComposerPage()
                } label: {
                    SettingsLabel(title: String(localized: "Composer"), systemImage: "keyboard")
                }

                NavigationLink {
                    SettingsChatPage()
                } label: {
                    SettingsLabel(title: String(localized: "Chat"), systemImage: "text.bubble")
                }

                NavigationLink {
                    SettingsNotificationsPage(server: server)
                } label: {
                    LabeledContent {
                        Text(isPushOn ? String(localized: "Push on") : String(localized: "Push off"))
                    } label: {
                        SettingsLabel(title: String(localized: "Notifications"), systemImage: "bell")
                    }
                }

                NavigationLink {
                    SettingsGeneralPage()
                } label: {
                    SettingsLabel(title: String(localized: "General"), systemImage: "gearshape")
                }
            } header: {
                Text(verbatim: "JARVIS")
            } footer: {
                Text("Applies on this iPhone to every server.")
            }

            Section {
                NavigationLink {
                    SettingsAboutPage()
                } label: {
                    LabeledContent {
                        Text(SettingsAboutPage.appVersion)
                    } label: {
                        SettingsLabel(title: String(localized: "About JARVIS"), systemImage: "info.circle")
                    }
                }

                if SettingsDeveloperPage.isAvailable {
                    NavigationLink {
                        SettingsDeveloperPage()
                    } label: {
                        SettingsLabel(title: "Developer", systemImage: "hammer")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .onAppear {
            isPushOn = PushRegistrar.shared?.pairing(for: server) != nil
        }
    }
}

/// The JARVIS server on the index: avatar, name, then its host.
private struct SettingsServerRow: View {
    let account: ServerAccount

    private var hostFallback: String {
        URL(string: account.urlString)?.host ?? account.urlString
    }

    private var name: String {
        account.displayName.isEmpty ? hostFallback : account.displayName
    }

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: account.displayName,
            storedInitials: account.initials,
            fallbackFullName: hostFallback
        )
    }

    private var detail: String { hostFallback }

    var body: some View {
        HStack(spacing: 12) {
            ServerAvatarBadge(initials: previewInitials, colorHex: account.headerLogoColorHex)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(name), \(account.urlString)"))
    }
}

#Preview {
    NavigationStack {
        SettingsView(authManager: AuthManager(), server: URL(staticString: "https://webui.example.test"))
    }
}
