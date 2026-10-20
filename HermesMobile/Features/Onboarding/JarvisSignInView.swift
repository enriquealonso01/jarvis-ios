import SwiftUI

/// First run: sign in to JARVIS. The host is baked in (`JarvisServer`), so this asks only for
/// the dashboard username and password, signs in once on a connection of its own (the version
/// gate, install check and `BotConnectionAdvice` copy all apply, as in Hermex's connect form)
/// and then adds the host as the app's one Hermes server. Nothing is saved until the host
/// accepted the password.
struct JarvisSignInView: View {
    @Bindable var authManager: AuthManager
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSigningIn = false
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    private var canSubmit: Bool {
        !isSigningIn && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        ZStack {
            JarvisBrand.obsidian.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        OrbitalCoreView(state: .idle, isStatic: true)
                            .frame(width: 148, height: 148)
                            .accessibilityHidden(true)
                        Text(verbatim: "JARVIS")
                            .font(.system(size: 34, weight: .semibold, design: .default))
                            .tracking(8)
                            .foregroundStyle(JarvisBrand.iceCore)
                        Text("Personal Intelligence")
                            .font(.subheadline)
                            .foregroundStyle(JarvisBrand.metallicGray)
                    }
                    .padding(.top, 56)

                    VStack(spacing: 12) {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focused, equals: .username)
                            .onSubmit { focused = .password }
                            .modifier(JarvisFieldStyle())
                            .accessibilityIdentifier("signin.username")
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focused, equals: .password)
                            .onSubmit { if canSubmit { Task { await signIn() } } }
                            .modifier(JarvisFieldStyle())
                            .accessibilityIdentifier("signin.password")

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("signin.error")
                        }

                        Button {
                            Task { await signIn() }
                        } label: {
                            Group {
                                if isSigningIn {
                                    ProgressView().tint(JarvisBrand.obsidian)
                                } else {
                                    Text("Sign In").font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(JarvisBrand.obsidian)
                            .background(JarvisBrand.jarvisCyan.opacity(canSubmit ? 1 : 0.45),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("signin.submit")
                    }
                    .padding(.horizontal, 24)

                    Text(verbatim: JarvisServer.displayHost)
                        .font(.footnote.monospaced())
                        .foregroundStyle(JarvisBrand.metallicGray.opacity(0.7))
                        .accessibilityIdentifier("signin.host")
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
        .onAppear { if username.isEmpty { focused = .username } }
    }

    /// Signs in on a connection of its own, then saves the record and makes the host the
    /// active server. A failure shows the same advice Hermex's connect form does.
    private func signIn() async {
        guard canSubmit else { return }
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        let address = JarvisServer.address
        // A host already in the registry (signed out, or left from an earlier build) signs in
        // through its own form instead; this screen only runs with nothing configured.
        let candidate = BotConnection(
            id: UUID(), name: "JARVIS", address: address,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password
        )
        let http = HermesConnection(connection: candidate)
        do {
            try await http.signIn()
        } catch {
            guard !(error is CancellationError) else { return }
            errorMessage = BotConnectionAdvice.message(for: error, address: address)
            return
        }
        var record = http.connection
        record.hermesVersion = http.serverVersion
        record.installID = http.serverInstallID
        if !authManager.addHermesServer(record) {
            errorMessage = authManager.lastErrorMessage
            return
        }
        if let account = authManager.activeServer {
            authManager.updateServerIdentity(account, displayName: "JARVIS", initials: "J",
                                             headerLogoColorHex: JarvisServer.headerColorHex)
        }
    }
}

extension JarvisServer {
    /// The header avatar's color: Jarvis Cyan.
    static let headerColorHex = "#3FD6F5"
}

private struct JarvisFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .foregroundStyle(JarvisBrand.iceCore)
            .background(JarvisBrand.deepSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(JarvisBrand.surfaceBorder, lineWidth: 1))
    }
}

#Preview {
    JarvisSignInView(authManager: AuthManager())
}
