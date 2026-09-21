import SwiftUI

/// "Call me back" — the async pattern: JARVIS finishes a task, then CALLS.
/// Two modes:
///   • Instant call   -> bridge POST /call     (VoIP push rings the phone now)
///   • Scheduled call -> bridge POST /schedule {at_iso, reason}
/// Both go to the push bridge (Caddy strips the /bridge prefix). The VoIP
/// push path currently fails at APNs with InvalidProviderToken (ASC-only p8,
/// no APNs capability) — calls still work in-app via the Calls tab; the
/// push-ring path lights up the moment Enrique installs an APNs-capable key.
struct CallMeSheet: View {
    /// Optional session context: the call reason references what JARVIS did.
    var sessionContext: String?

    @Environment(\.dismiss) private var dismiss
    @State private var when = "now"           // now | 15m | 1h | evening | custom
    @State private var what = ""              // what to call about
    @State private var sending = false
    @State private var resultText: String?
    @State private var success = false

    private let options = ["now", "in 15 minutes", "in 1 hour", "this evening"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Call me about") {
                    TextField(placeholderText, text: $what, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("When") {
                    Picker("Timing", selection: $when) {
                        ForEach(options, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let ctx = sessionContext, !ctx.isEmpty {
                    Section {
                        Label(ctx, systemImage: "bubble.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let r = resultText {
                    Section {
                        Label(r, systemImage: success ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(success ? Color.green : Color.red)
                    }
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(success ? "Done" : "Ask JARVIS to call")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(sending || success)
                }
            }
            .navigationTitle("Call me back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var placeholderText: String {
        sessionContext == nil ? "e.g. weekly summary, done with the deploy…"
                              : "e.g. once you finish reviewing this session…"
    }

    private func dueISO() -> String? {
        let cal = Calendar.current
        let now = Date()
        let due: Date?
        switch when {
        case "in 15 minutes": due = now.addingTimeInterval(15 * 60)
        case "in 1 hour": due = now.addingTimeInterval(60 * 60)
        case "this evening":
            due = cal.nextDate(after: now, matching: DateComponents(hour: 20, minute: 30),
                               matchingPolicy: .nextTime)
        default: due = nil // "now"
        }
        guard let d = due else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    @MainActor
    private func send() async {
        sending = true
        resultText = nil
        defer { sending = false }
        let bridgeBase = ServerConfig.shared.config.bridgeBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let reason = what.isEmpty ? "JARVIS check-in (from iOS app)" : what
        do {
            if when == "now" {
                struct CallResp: Decodable { let call_id: String; let pushed: Bool }
                let resp = try await CCClient.shared.post(
                    bridgeBase + "/call",
                    body: ["reason": reason, "scheduled_by": "ios-call-me"],
                    as: CallResp.self)
                success = true
                resultText = resp.pushed
                    ? "Ringing now (call \(resp.call_id))"
                    : "Call \(resp.call_id) placed, but the ring push was rejected (APNs key lacks push capability — see Settings). Open the Calls tab to connect in-app."
            } else if let at = dueISO() {
                struct SchedResp: Decodable { let call_id: String; let scheduled: Bool; let at: String }
                let resp = try await CCClient.shared.post(
                    bridgeBase + "/schedule",
                    body: ["at_iso": at, "reason": reason, "scheduled_by": "ios-call-me"],
                    as: SchedResp.self)
                success = true
                resultText = "Scheduled for \(resp.at) (call \(resp.call_id))"
            } else {
                resultText = "Pick a timing first"
            }
        } catch {
            resultText = "Failed: \(error.localizedDescription)"
        }
    }
}
