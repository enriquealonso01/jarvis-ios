import SwiftData
import SwiftUI

/// One server's page (#1252): its identity, then its connection and sessions, then the way to
/// switch to it, sign out of it, or remove it. The active server's sections load from it;
/// another server shows only what this iPhone saved.
struct SettingsServerPage: View {
    @Bindable var authManager: AuthManager
    let account: ServerAccount
    let onDefaultProfileSelected: (DefaultProfileSelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var displayName: String
    @State private var initials: String
    @State private var colorHex: String
    @State private var isConfirmingRemove = false
    @State private var isConfirmingSignOut = false
    @State private var isRemoving = false
    /// Set only while this is the active webui server, the one kind whose page loads settings.
    @State private var webui: WebuiServerSettingsModel?
    /// The active Hermes server's saved connection, read on appear (#899): its username shows
    /// on the connection row, and Archived Sessions reads through it (#1048).
    @State private var hermesConnection: BotConnection?

    init(
        authManager: AuthManager,
        account: ServerAccount,
        onDefaultProfileSelected: @escaping (DefaultProfileSelection) -> Void
    ) {
        self.authManager = authManager
        self.account = account
        self.onDefaultProfileSelected = onDefaultProfileSelected
        _displayName = State(initialValue: account.displayName)
        _initials = State(initialValue: account.initials)
        _colorHex = State(initialValue: account.headerLogoColorHex)
        if account.id == authManager.activeServerID, account.kind == .webui, let server = URL(string: account.urlString) {
            _webui = State(initialValue: WebuiServerSettingsModel(server: server, onAPIError: authManager.handleAPIError))
        }
    }

    private var server: URL? { URL(string: account.urlString) }
    private var isActive: Bool { account.id == authManager.activeServerID }
    private var hasOtherServers: Bool { authManager.servers.count > 1 }
    private var hostFallback: String { server?.host ?? account.urlString }
    /// The active Hermes server, whose page shows its sign-in, release, and update standing.
    private var activeHermesServer: URL? { isActive && account.kind == .hermes ? server : nil }

    var body: some View {
        let page = List {
            Section(String(localized: "Identity")) {
                ServerIdentityEditor(
                    displayName: $displayName,
                    initials: $initials,
                    colorHex: $colorHex,
                    fallbackName: hostFallback
                )
            }

            if let webui {
                WebuiServerSections(authManager: authManager, model: webui)
            } else if let server = activeHermesServer {
                hermesSections(server: server)
            } else {
                inactiveServerSection
            }

            accountSections
        }
        .settingsPage(displayName.isEmpty ? hostFallback : displayName)
        // Persist identity edits to this server's registry entry. When it's the
        // active server, the registry mirrors them into the global @AppStorage so
        // the avatar / header tint update live (#17).
        .onChange(of: displayName) { persistIdentity() }
        .onChange(of: initials) { persistIdentity() }
        .onChange(of: colorHex) { persistIdentity() }
        .task {
            guard let server = activeHermesServer else { return }
            // A Hermes server has no webui to load from, so no webui 401 can sign it out (#899).
            hermesConnection = try? BotConnectionStore().load(server: server)
            let updates = HermesUpdateModel.for(server: server)
            updates.onUpdated = { version in
                authManager.hermesServerUpdated(server: server, to: version)
            }
            await updates.appear()
        }
        .onDisappear {
            if let server = activeHermesServer { HermesUpdateModel.for(server: server).leaveSettings() }
        }
        .alert(removeAlertTitle, isPresented: $isConfirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button(removeButtonTitle, role: .destructive) {
                Task { await remove() }
            }
        } message: {
            Text(removeAlertMessage)
        }
        .alert("Sign out of this server?", isPresented: $isConfirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    // Purge this server's offline cache before signing out, while
                    // the view (and its modelContext) is still alive. Best-effort:
                    // the cache is server-keyed, so a leftover row can never surface
                    // as another server's.
                    if let server { try? CacheStore.clearCache(for: server, in: modelContext) }
                    await authManager.signOut()
                    dismiss()
                }
            }
        } message: {
            Text("Deletes this server's saved sign-in and shows its sign-in form.")
        }

        if let webui {
            page.webuiServerPresentations(webui, onDefaultProfileSelected: onDefaultProfileSelected)
        } else {
            page
        }
    }

    /// The active Hermes server's sign-in, with its headers, the release saved at that sign-in,
    /// and the host's update standing (#1075).
    @ViewBuilder
    private func hermesSections(server: URL) -> some View {
        Section {
            LabeledContent(String(localized: "URL")) {
                Text(account.urlString).textSelection(.enabled)
            }

            NavigationLink {
                BotConnectionView(server: server) { authManager.hermesSignInSaved(server: server) }
            } label: {
                LabeledContent {
                    Text(hermesConnection?.username ?? "")
                } label: {
                    SettingsLabel(title: String(localized: "Hermes connection"), systemImage: "person.badge.key")
                }
            }

            if let version = account.serverVersion {
                LabeledContent(String(localized: "Version"), value: version)
            }

            HermesUpdateCallout(model: HermesUpdateModel.for(server: server), version: account.serverVersion)
        } header: {
            Text("Server")
        }

        if let hermesConnection {
            Section(String(localized: "Sessions")) {
                NavigationLink {
                    ArchivedSessionsView(server: server, hermes: .saved(hermesConnection, server: server, profile: nil))
                } label: {
                    SettingsLabel(title: String(localized: "Archived Sessions"), systemImage: "archivebox")
                }
            }
        }
    }

    /// A server that isn't active shows what this iPhone saved for it, and its Hermes sign-in.
    @ViewBuilder
    private var inactiveServerSection: some View {
        Section {
            LabeledContent(String(localized: "URL")) {
                Text(account.urlString).textSelection(.enabled)
            }

            LabeledContent(String(localized: "Status")) {
                SettingsStatusPill(label: String(localized: "Inactive"))
            }

            // Not behind the Bot Mode preview gate (#557): this login is what push pairing
            // needs. On a Hermes server it is the server's own sign-in, and saving it signs a
            // signed-out server back in (#899).
            if let server {
                NavigationLink {
                    BotConnectionView(server: server) { authManager.hermesSignInSaved(server: server) }
                } label: {
                    SettingsLabel(
                        title: String(localized: "Hermes connection"),
                        systemImage: account.kind == .hermes ? "person.badge.key" : "bell.badge",
                        note: account.kind == .hermes ? nil : String(localized: "Needed for notifications and Bots.")
                    )
                }
            }
        } header: {
            Text("Server")
        }
    }

    @ViewBuilder
    private var accountSections: some View {
        // Signing out keeps a Hermes server and shows its sign-in form (#899); a webui
        // server's sign-out removes it, below.
        if activeHermesServer != nil {
            Section {
                Button(String(localized: "Sign Out of This Server"), role: .destructive) {
                    isConfirmingSignOut = true
                }
            } footer: {
                Text("Deletes the saved sign-in; the server stays.")
            }
        }

        Section {
            Button(role: .destructive) {
                isConfirmingRemove = true
            } label: {
                if isRemoving {
                    ProgressView()
                } else {
                    Text(removeButtonTitle)
                }
            }
            .disabled(isRemoving)
        } footer: {
            Text(removeFootnote)
        }
    }

    private func persistIdentity() {
        authManager.updateServerIdentity(
            account,
            displayName: displayName,
            initials: initials,
            headerLogoColorHex: colorHex
        )
    }

    private func remove() async {
        let wasActive = isActive
        isRemoving = true
        // Purge this server's offline cache *before* removing it, while
        // the view (and its modelContext) is still alive — removing the
        // active server flips auth state and tears this stack down on
        // its own. Best-effort: the cache is server-keyed, so a leftover
        // row can never surface as another server's content (#18, PR
        // #286 W2).
        if let server {
            try? CacheStore.clearCache(for: server, in: modelContext)
            await ChatDraftStore.shared.discardDrafts(for: server)
        }
        await authManager.removeServer(account)
        // Only a non-active removal leaves this view alive to reset its
        // state and pop; the active-server case is already torn down.
        if !wasActive {
            isRemoving = false
            dismiss()
        }
    }

    /// Whether this page's remove button signs out of the active webui server, which also
    /// removes it. An active Hermes server is removed here under that name instead, because
    /// its Sign Out keeps the server and shows its sign-in form (#899).
    private var signsOut: Bool { isActive && account.kind == .webui }

    private var removeButtonTitle: String {
        signsOut ? String(localized: "Sign Out of This Server") : String(localized: "Remove Server")
    }

    private var removeAlertTitle: String {
        if signsOut { return String(localized: "Sign out of this server?") }
        return String(localized: "Remove this server?")
    }

    private var removeFootnote: String {
        signsOut
            ? String(localized: "Signs out and removes this server from this iPhone.")
            : String(localized: "Removes this server from this iPhone.")
    }

    private var removeAlertMessage: String { usualRemovalMessage }

    private var usualRemovalMessage: String {
        if signsOut {
            return hasOtherServers
                ? String(localized: "You'll switch to another configured server. Sign in again to use this one.")
                : String(localized: "You'll return to onboarding and need the server URL and password to sign back in.")
        }
        if isActive { return activeHermesRemovalText }
        return String(localized: "This removes the server and its saved settings on this device. Your active server is unaffected.")
    }

    private var activeHermesRemovalText: String {
        hasOtherServers
            ? String(localized: "Removes this server, its saved sign-in and its Bot data on this device, then switches to another configured server.")
            : String(localized: "Removes this server, its saved sign-in and its Bot data on this device, then returns to onboarding.")
    }
}

/// Reusable per-server identity editor (display name, initials, Header Logo Color),
/// used by the server page (#17).
struct ServerIdentityEditor: View {
    @Binding var displayName: String
    @Binding var initials: String
    @Binding var colorHex: String
    /// Host-derived fallback used for the avatar preview when fields are empty.
    let fallbackName: String

    private var previewInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: displayName.isEmpty ? fallbackName : displayName,
            storedInitials: initials,
            fallbackFullName: fallbackName
        )
    }

    private var initialsBinding: Binding<String> {
        Binding(
            get: { initials },
            set: { initials = SessionIdentitySettings.normalizedInitials($0) }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { HeaderLogoColor.color(for: colorHex) },
            set: { if let hex = HeaderLogoColor.hexString(from: $0) { colorHex = hex } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ServerAvatarBadge(initials: previewInitials, colorHex: colorHex, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Server Avatar")
                        .font(AppFont.subheadline(weight: .medium))

                    Text("Stored on this device only.")
                        .font(AppFont.caption())
                        .foregroundStyle(.secondary)
                }
            }

            SettingsTextFieldRow(
                title: String(localized: "Display Name"),
                text: $displayName,
                placeholder: fallbackName.isEmpty ? String(localized: "Server") : fallbackName
            )

            SettingsDivider()

            SettingsTextFieldRow(title: String(localized: "Initials"), text: initialsBinding, placeholder: previewInitials)

            SettingsDivider()

            HeaderLogoColorSettings(selectedHex: $colorHex, customColor: colorBinding)
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 2)
            .opacity(0.72)
    }
}
