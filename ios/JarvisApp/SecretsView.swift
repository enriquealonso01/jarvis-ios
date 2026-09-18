import SwiftUI
import LocalAuthentication

/// Secrets tab (backlog #3): named-secret manager backed by the push bridge's
/// server-side store (`/secrets` family on the bridge origin). Values are typed
/// once, sent over TLS, persisted server-side (0600), masked after save, and
/// NEVER stored on device or echoed back by the API.
/// Backlog #9: optional Face ID gate (Settings toggle) + shared haptics.
struct SecretMeta: Decodable, Identifiable {
    let name: String
    let masked: String?
    let length: Int?
    let updated_at: String?
    let updated_by: String?
    var id: String { name }
}

struct SecretsListResp: Decodable { let secrets: [SecretMeta] }
struct SecretWriteResp: Decodable { let ok: Bool?; let created: Bool?; let deleted: Bool? }

struct SecretsView: View {
    @State private var secrets: [SecretMeta] = []
    @State private var newName = ""
    @State private var newValue = ""
    @State private var loading = false
    @State private var status: String?
    @State private var loadFailed = false
    @State private var confirmDelete: SecretMeta?
    @State private var unlocked = false
    @AppStorage("jarvis.settings.faceid") private var faceIDLock = false

    var body: some View {
        NavigationStack {
            Group {
                if faceIDLock && !unlocked {
                    lockedView
                } else {
                    secretsList
                }
            }
            .navigationTitle("Secrets")
        }
    }

    /// Face ID gate (backlog #9): nothing renders until biometrics pass.
    private var lockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "faceid")
                .font(.system(size: 48))
                .foregroundStyle(Color.jarvisAccent)
            Text("Secrets are locked")
                .font(.headline)
            Button("Unlock") { unlock() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .task { unlock() }
    }

    private func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            unlocked = true   // no biometrics/passcode on device — don't brick the tab
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "Unlock JARVIS secrets") { ok, _ in
            Task { @MainActor in
                unlocked = ok
                if ok { Haptics.success() } else { Haptics.error() }
            }
        }
    }

    private var secretsList: some View {
        List {
                Section {
                    // Load failure ≠ empty server: a transient bridge outage
                    // must show the error, not the lie "No secrets stored"
                    // (the empty check below only runs when the fetch SUCCEEDED).
                    if secrets.isEmpty && !loading && !loadFailed {
                        Text("No secrets stored. Values live server-side only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if loadFailed && secrets.isEmpty {
                        Label("Can't reach the bridge — secrets NOT loaded.", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.red)
                    }
                    ForEach(secrets) { s in
                        HStack {
                            Image(systemName: "key.fill").foregroundStyle(Color.jarvisAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.callout.monospaced())
                                Text(maskLine(s)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                confirmDelete = s
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Named secrets")
                } footer: {
                    Text("Values never leave the server after save. Names only here.")
                }

                Section("Add / update secret") {
                    TextField("Name (e.g. APNS_KEY_ID)", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    SecureField("Value", text: $newValue)
                        .font(.callout.monospaced())
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Image(systemName: "lock.shield.fill")
                            Text("Save to server")
                        }
                    }
                    .disabled(newName.isEmpty || newValue.isEmpty || loading)
                    if let status {
                        Label(status, systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .confirmationDialog("Delete \(confirmDelete?.name ?? "")?",
                                isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete secret", role: .destructive) {
                    if let s = confirmDelete { Task { await delete(s) } }
                    confirmDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            } message: {
                Text("The value is removed from the server. This cannot be undone.")
            }
    }

    private func maskLine(_ s: SecretMeta) -> String {
        var parts: [String] = []
        if let m = s.masked { parts.append(m) }
        if let l = s.length { parts.append("\(l) chars") }
        if let by = s.updated_by, !by.isEmpty { parts.append("by \(by)") }
        return parts.joined(separator: " · ")
    }

    private func bridgeBase() -> String {
        ServerConfig.shared.config.bridgeBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let resp = try await CCClient.shared.get("\(bridgeBase())/secrets", as: SecretsListResp.self)
            secrets = resp.secrets
            loadFailed = false
        } catch {
            status = nil
            // Keep last-known-good entries; a transient outage must not look
            // like an empty server (the list view now shows the load error).
            loadFailed = true
        }
    }

    @MainActor
    private func save() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !newValue.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let resp: SecretWriteResp = try await CCClient.shared.post(
                "\(bridgeBase())/secrets/set",
                body: ["name": name, "value": newValue, "updated_by": "ios-app"],
                as: SecretWriteResp.self)
            newValue = ""
            newName = ""
            status = (resp.created ?? true) ? "Saved — masked on server, never stored here." : "Updated — value rotated."
            Haptics.success()
            await load()
        } catch {
            status = nil
            Haptics.error()
        }
    }

    @MainActor
    private func delete(_ s: SecretMeta) async {
        loading = true
        defer { loading = false }
        do {
            let _: SecretWriteResp = try await CCClient.shared.post(
                "\(bridgeBase())/secrets/delete",
                body: ["name": s.name],
                as: SecretWriteResp.self)
            Haptics.success()
            await load()
        } catch {
            Haptics.error()
        }
    }
}
