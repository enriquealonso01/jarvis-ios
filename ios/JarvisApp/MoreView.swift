import SwiftUI

/// "More" tab: capability packs + settings + secrets. Minimal by design —
/// JARVIS core is Sessions/Calls; everything optional lives behind here.
struct MoreView: View {
    @StateObject private var caps = CapabilityRegistry.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Capability Packs") {
                    if caps.packs.isEmpty {
                        Text("No packs installed. Health, photos, location and other packs plug in here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // `any CapabilityPack` is not Identifiable-conforming as a
                    // collection element in Swift 6 — key by index instead.
                    ForEach(Array(caps.packs.enumerated()), id: \.offset) { _, pack in
                        HStack {
                            Image(systemName: pack.symbol)
                                .frame(width: 26)
                                .foregroundStyle(pack.isEnabled ? Color.jarvisAccent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.displayName)
                                Text(pack.isEnabled ? "Enabled" : "Disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Section("Server") {
                    NavigationLink {
                        SecretsView()
                    } label: {
                        Label("Named Secrets", systemImage: "key.fill")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("More")
            .onAppear {
                // Packs self-register; the template pack proves the wiring.
                CapabilityRegistry.shared.register(ExampleCapabilityPack())
            }
        }
    }
}
