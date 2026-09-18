import SwiftUI

/// Secrets tab placeholder UI for this increment: named-secret manager that
/// POSTs to the gateway's secret-scope endpoint. Values are typed, sent once
/// over TLS, masked after save, and never persisted client-side.
/// The wire-up to the live gateway secret scope lands with backlog #3.
struct SecretsView: View {
    @State private var names: [String] = []
    @State private var newName = ""
    @State private var newValue = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            List {
                Section("Named secrets") {
                    if names.isEmpty {
                        Text("No secrets stored. Values live server-side only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(names, id: \.self) { n in
                        HStack {
                            Image(systemName: "key.fill").foregroundStyle(Color.jarvisAccent)
                            Text(n).font(.callout.monospaced())
                            Spacer()
                            Text("••••••••").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Add secret") {
                    TextField("Name (e.g. APNS_KEY_ID)", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    SecureField("Value", text: $newValue)
                    Button("Save to gateway") {
                        // TODO(backlog #3): POST gateway secret-scope endpoint
                        if !newName.isEmpty, !newValue.isEmpty {
                            names.append(newName)
                            newName = ""; newValue = ""
                            saved = true
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                    .disabled(newName.isEmpty || newValue.isEmpty)
                    if saved {
                        Label("Saved — value masked, never stored on device.", systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Secrets")
        }
    }
}
