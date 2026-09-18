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
                    LabeledField("Voice Gateway URL", text: $voice, placeholder: "https://voice.enriquecodes.com")
                }
            }
            Button {
                ServerConfig.shared.config = ServerConfig(
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

/// Settings tab lives under Home's gear for now — server URL + token + logout.
struct SettingsView: View {
    @ObservedObject private var server = ServerConfig.shared
    @ObservedObject private var auth = AuthStore.shared

    var body: some View {
        Form {
            Section("Server") {
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
            }
            Section("Session") {
                LabeledContent("Signed in", value: auth.isAuthed ? "Yes" : "No")
                LabeledContent("Token expires", value: Date(timeIntervalSince1970: auth.expiresAt).formatted())
                Button("Sign Out", role: .destructive) { auth.logout() }
            }
        }
    }
}
