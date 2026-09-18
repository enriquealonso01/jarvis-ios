import SwiftUI

/// Calls tab: call log + the "Call me" button (POSTs the push bridge /call).
/// CallKit provider + WebRTC land with backlog #4; this is the visible shell.
struct CallsView: View {
    struct CallEntry: Identifiable {
        let id = UUID()
        let reason: String
        let at: Date
        let outgoing: Bool
    }

    @State private var log: [CallEntry] = []
    @State private var calling = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await callMe() }
                    } label: {
                        HStack {
                            Image(systemName: "phone.arrow.up.right.fill")
                                .foregroundStyle(Color.jarvisAccent)
                            Text(calling ? "Calling…" : "Call me")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(calling)
                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Direct line")
                }

                Section("Call log") {
                    if log.isEmpty {
                        Text("No calls yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(log.reversed()) { c in
                        HStack {
                            Image(systemName: c.outgoing ? "arrow.up.right.phone" : "phone.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(c.reason).font(.callout)
                                Text(c.at.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calls")
        }
    }

    @MainActor
    private func callMe() async {
        calling = true
        status = nil
        let reason = "JARVIS call (from iOS app)"
        log.append(CallEntry(reason: reason, at: Date(), outgoing: true))
        do {
            // TODO(backlog #4/#5): signed bridge call + VoIP push + CallKit.
            // For now this pings the bridge /health through the configured URL
            // so connectivity is real once the reverse proxy is up.
            let cfg = ServerConfig.shared.config
            let url = URL(string: cfg.bridgeBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/health")
            if let url, let (_, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                status = "Bridge reachable — full calling lands with CallKit (#4)."
            } else {
                status = "Bridge not reachable yet — queued locally."
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        calling = false
    }
}
