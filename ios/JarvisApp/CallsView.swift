import SwiftUI

/// Calls tab (backlog #4): "Call me" via bridge /call (Bearer auth now
/// accepted), live call state from CallManager, scheduled calls list/cancel.
struct CallsView: View {
    struct CallEntry: Identifiable {
        let id = UUID()
        let reason: String
        let at: Date
        let outgoing: Bool
    }

    struct ScheduledCall: Identifiable, Decodable {
        let call_id: String
        let at_iso: String
        let reason: String
        let scheduled_by: String?
        var id: String { call_id }
    }

    @ObservedObject private var mgr = CallManager.shared
    @State private var log: [CallEntry] = []
    @State private var scheduled: [ScheduledCall] = []
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
                    if mgr.callState != "idle" {
                        HStack {
                            Circle().fill(mgr.callState.hasPrefix("failed") ? Color.red : Color.green)
                                .frame(width: 8, height: 8)
                            Text("JARVIS call — \(mgr.callState)").font(.callout)
                        }
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

                Section {
                    if scheduled.isEmpty {
                        Text("Nothing scheduled.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(scheduled) { s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.reason).font(.callout)
                                Text(s.at_iso).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await cancel(s.call_id) }
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Scheduled")
                }
            }
            .navigationTitle("Calls")
            .refreshable { await loadScheduled() }
            .task { await loadScheduled() }
        }
    }

    @MainActor
    private func callMe() async {
        calling = true
        status = nil
        defer { calling = false }
        do {
            let resp = try await CCClient.shared.post(
                ServerConfig.shared.config.bridgeBaseURL + "/call",
                body: ["reason": "JARVIS call (from iOS app)", "scheduled_by": "ios-app"],
                as: CallResp.self)
            status = resp.pushed
                ? "VoIP push sent — answer via CallKit when it rings."
                : "Bridge accepted the call (APNs not configured yet — push queued server-side)."
            log.append(CallEntry(reason: "JARVIS call (from iOS app)", at: Date(), outgoing: true))
            Haptics.success()
        } catch {
            status = "Call failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    @MainActor
    private func loadScheduled() async {
        // GET /schedule/list authenticates with HMAC over an empty body on the
        // agent side; the Bearer path isn't enabled for GETs, so we read via a
        // signed helper only if the app ever gets one. For now: hidden unless
        // the bridge later adds Bearer GET support.
        struct ListResp: Decodable { let scheduled: [ScheduledCall] }
        // Attempt a Bearer GET; if the bridge starts accepting it this lights up.
        do {
            let resp = try await CCClient.shared.get(
                ServerConfig.shared.config.bridgeBaseURL + "/schedule/list",
                as: ListResp.self)
            scheduled = resp.scheduled
        } catch {
            scheduled = []
        }
    }

    @MainActor
    private func cancel(_ id: String) async {
        do {
            let resp = try await CCClient.shared.post(
                ServerConfig.shared.config.bridgeBaseURL + "/schedule/cancel",
                body: ["call_id": id],
                as: CancelResp.self)
            if resp.cancelled ?? 0 > 0 {
                scheduled.removeAll { $0.call_id == id }
                Haptics.success()
            }
        } catch {
            Haptics.error()
        }
    }
}

struct CallResp: Decodable { let call_id: String; let pushed: Bool }
struct CancelResp: Decodable { let cancelled: Int? }
