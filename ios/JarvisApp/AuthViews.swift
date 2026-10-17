import SwiftUI

/// First-run: server URL entry (defaults filled from the standard deployment).
struct SetupView: View {
    @State private var base = ServerConfig.shared.config.baseURL
    @State private var bridge = ServerConfig.shared.config.bridgeBaseURL
    @State private var voice = ServerConfig.shared.config.voiceGWURL

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "circle.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.jarvisAccent)
                Text("JARVIS")
                    .font(.largeTitle.bold())
                Text("Control Center, native.")
                    .foregroundStyle(.secondary)
            }
            GlassCard {
                VStack(spacing: 14) {
                    LabeledField("Dashboard URL", text: $base, placeholder: "https://jarvis.enriquecodes.com")
                    LabeledField("Bridge URL", text: $bridge, placeholder: "https://bridge.enriquecodes.com")
                    LabeledField("Voice Gateway URL", text: $voice, placeholder: "https://jarvis.enriquecodes.com")
                }
            }
            Button {
                ServerConfig.shared.config = ServerConfigValues(
                    baseURL: base, bridgeBaseURL: bridge, voiceGWURL: voice
                )
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding(20)
    }
}

struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    init(_ label: String, text: Binding<String>, placeholder: String = "") {
        self.label = label
        _text = text
        self.placeholder = placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// Sign-in with the dashboard's basic credentials → native PKCE flow.
struct LoginView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @ObservedObject private var auth = AuthStore.shared

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.jarvisAccent)
                Text("Sign in")
                    .font(.title2.bold())
            }
            GlassCard {
                VStack(spacing: 14) {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let err = auth.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
            Button {
                busy = true
                Task {
                    await AuthStore.shared.login(username: username, password: password)
                    busy = false
                }
            } label: {
                if busy {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Sign In").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || username.isEmpty || password.isEmpty)
            Spacer()
        }
        .padding(20)
    }
}

/// Settings (backlog #9): server URLs, auth token (manual entry / paste for
/// debugging + refresh fallback), connection test, session info, sign out.
struct SettingsView: View {
    @ObservedObject private var server = ServerConfig.shared
    @ObservedObject private var auth = AuthStore.shared
    @State private var manualToken = ""
    @State private var tokenRevealed = false
    @State private var testResult: String?
    @State private var testing = false
    @AppStorage("jarvis.settings.faceid") private var faceIDLock = false
    // App lock prefs live in the Keychain (AppLockStore); the @State mirror
    // drives the toggles and writes through on change.
    @State private var appLockEnabled = AppLockStore.shared.lockEnabled
    @State private var appLockLaunchOnly = AppLockStore.shared.requireOnLaunchOnly
    // Haptics gate: UserDefaults (cosmetic knob), read by Haptics itself.
    @AppStorage(Haptics.enabledKey) private var hapticsEnabled = true
    @State private var theme = AppTheme.current

    var body: some View {
        Form {
            Section {
                LabeledField("Dashboard URL", text: Binding(
                    get: { server.config.baseURL },
                    set: { server.config.baseURL = $0 }
                ))
                LabeledField("Bridge URL", text: Binding(
                    get: { server.config.bridgeBaseURL },
                    set: { server.config.bridgeBaseURL = $0 }
                ))
                LabeledField("Voice Gateway URL", text: Binding(
                    get: { server.config.voiceGWURL },
                    set: { server.config.voiceGWURL = $0 }
                ))
            } header: {
                Text("Server")
            } footer: {
                Text("Defaults point at jarvis.enriquecodes.com. Only change if the deployment moves.")
            }

            Section("Connection test") {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(testing ? "Testing…" : "Test connection")
                    }
                }
                .disabled(testing)
                if let testResult {
                    Label(testResult, systemImage: testResult.hasPrefix("OK") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                }
            }

            Section {
                if auth.isAuthed {
                    LabeledContent("Signed in", value: "Yes")
                    LabeledContent("Token expires", value: Date(timeIntervalSince1970: auth.expiresAt).formatted())
                } else {
                    LabeledContent("Signed in", value: "No")
                }
                if tokenRevealed, !manualToken.isEmpty {
                    Text(manualToken)
                        .font(.caption2.monospaced())
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                SecureField("Paste access token (manual)", text: $manualToken)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Apply pasted token") {
                    let t = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    auth.applyManualToken(t)
                    manualToken = ""
                    Haptics.success()
                }
                .disabled(manualToken.trimmingCharacters(in: .whitespaces).isEmpty)
                if auth.isAuthed {
                    Button("Copy access token", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = auth.accessToken
                        Haptics.tap()
                    }
                }
            } header: {
                Text("Auth token")
            } footer: {
                Text("Normally you sign in with username/password. Manual token entry is a fallback for debugging or server-side minted sessions.")
            }

            Section {
                Toggle("Lock app with Face ID", isOn: $appLockEnabled)
                if appLockEnabled {
                    Toggle("Only on launch", isOn: $appLockLaunchOnly)
                }
            } header: {
                Text("App lock")
            } footer: {
                Text(appLockEnabled
                     ? (appLockLaunchOnly
                        ? "JARVIS asks for Face ID (or passcode) when the app cold-launches. Mid-session returns stay unlocked."
                        : "JARVIS asks for Face ID (or passcode) on launch and every time you come back to the app.")
                     : "JARVIS opens without a lock. The preference is stored in the Keychain.")
            }

            Section {
                Toggle("Haptics", isOn: $hapticsEnabled)
                Picker("Theme", selection: $theme) {
                    ForEach(AppTheme.allCases) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                LabeledContent("Version",
                               value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
            } header: {
                Text("Appearance & feedback")
            } footer: {
                Text("Theme takes effect immediately; dark matches the JARVIS identity.")
            }

            Section {
                Toggle("Lock Secrets with Face ID", isOn: $faceIDLock)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Requires Face ID (or passcode) every time the Secrets tab opens.")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    auth.logout()
                    Haptics.warning()
                }
            }
        }
        .navigationTitle("Settings")
        .onChange(of: appLockEnabled) { _, on in
            AppLockStore.shared.lockEnabled = on
            if on {
                // Enabling the lock re-locks immediately so the user confirms
                // biometrics work BEFORE relying on it (no lockout surprise
                // at next launch).
                AppLockController.shared.isLocked = true
                AppLockController.shared.authenticate()
            }
        }
        .onChange(of: appLockLaunchOnly) { _, on in
            AppLockStore.shared.requireOnLaunchOnly = on
        }
        .onChange(of: theme) { _, newTheme in
            AppTheme.set(newTheme)
        }
    }

    @MainActor
    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            struct Ping: Decodable { let cpu_pct: Double? }
            let _: Ping = try await CCClient.shared.get("/api/control/vitals", as: Ping.self)
            testResult = "OK — dashboard reachable"
            Haptics.success()
        } catch {
            testResult = "FAIL — \(error.localizedDescription)"
            Haptics.error()
        }
    }
}
