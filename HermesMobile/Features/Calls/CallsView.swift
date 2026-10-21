import SwiftUI

/// Calls (requirement 3, ported from the v1 Calls tab): talk to JARVIS now, ask JARVIS to call
/// back now or later (push bridge `/call`, `/schedule`), the scheduled calls with cancel, and
/// the call log. Every call is a CallKit call, so it rings on the lock screen and keeps going
/// with the screen off.
struct CallsView: View {
    struct ScheduledCall: Identifiable, Equatable {
        let id: String
        let at: String
        let reason: String
    }

    @ObservedObject private var manager = CallManager.shared
    @ObservedObject private var callLog = CallLogStore.shared
    @ObservedObject private var voice = JarvisVoicePresenter.shared
    @State private var scheduled: [ScheduledCall] = []
    @State private var scheduleError: String?
    @State private var isShowingCallMe = false

    var body: some View {
        List {
            Section {
                Button {
                    voice.startConversation()
                } label: {
                    Label(manager.activeCallUUID == nil ? "Talk to JARVIS" : "Open the live call",
                          systemImage: "waveform.circle.fill")
                        .font(.headline)
                }
                .accessibilityIdentifier("calls.talk")

                Button {
                    isShowingCallMe = true
                } label: {
                    Label("Ask JARVIS to call me…", systemImage: "phone.arrow.down.left")
                }
                .accessibilityIdentifier("calls.callMe")

                if manager.activeCallUUID != nil {
                    LabeledContent {
                        Text(verbatim: manager.callState)
                    } label: {
                        Text("Live call")
                    }
                }
            } footer: {
                Text("Calls ring like a phone call, on the lock screen too. You can also tell JARVIS in any chat, Signal or WhatsApp: \"call me in 10 minutes about the deploy\".")
            }

            Section("Scheduled") {
                if let scheduleError {
                    Text(verbatim: scheduleError).font(.footnote).foregroundStyle(.secondary)
                } else if scheduled.isEmpty {
                    Text("No calls scheduled.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(scheduled) { call in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: call.reason)
                        Text(verbatim: Self.displayTime(call.at)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Cancel", role: .destructive) { Task { await cancel(call) } }
                    }
                }
            }

            Section("Recent") {
                if callLog.entries.isEmpty {
                    Text("No calls yet.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(callLog.entries.reversed()) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.outgoing ? "arrow.up.right" : "arrow.down.left")
                            .foregroundStyle(entry.outcome == "missed" || entry.outcome?.hasPrefix("failed") == true
                                             ? Color.red : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.reason.isEmpty ? "JARVIS" : entry.reason).lineLimit(2)
                            Text(verbatim: Self.detail(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Calls")
        .refreshable { await loadScheduled() }
        .task { await loadScheduled() }
        .sheet(isPresented: $isShowingCallMe, onDismiss: { Task { await loadScheduled() } }) {
            CallMeSheet()
        }
    }

    private func loadScheduled() async {
        do {
            let reply = try await JarvisCallEndpoints.bridgeRequest("schedule/list")
            let rows = reply["scheduled"] as? [[String: Any]] ?? []
            scheduled = rows.compactMap { row in
                guard let id = row["call_id"] as? String else { return nil }
                return ScheduledCall(id: id, at: row["at_iso"] as? String ?? "", reason: row["reason"] as? String ?? "")
            }
            scheduleError = nil
        } catch {
            scheduleError = error.localizedDescription
        }
    }

    private func cancel(_ call: ScheduledCall) async {
        _ = try? await JarvisCallEndpoints.bridgeRequest("schedule/cancel", method: "POST", body: ["call_id": call.id])
        await loadScheduled()
    }

    static func displayTime(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? iso
    }

    static func detail(_ entry: CallLogStore.Entry) -> String {
        var parts = [entry.at.formatted(date: .abbreviated, time: .shortened)]
        if let outcome = entry.outcome { parts.append(outcome) }
        if let seconds = entry.durationSeconds, seconds > 0 {
            parts.append(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
        }
        if let quality = CallLogStore.audioQualityLabel(inFrames: entry.audioInFrames, outFrames: entry.audioOutFrames) {
            parts.append(quality)
        }
        return parts.joined(separator: " · ")
    }
}

/// "Call me back", ported from the v1 app: now (`/call`) or later (`/schedule`), about anything.
struct CallMeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var when = Timing.now
    @State private var what = ""
    @State private var isSending = false
    @State private var result: String?
    @State private var succeeded = false

    enum Timing: String, CaseIterable, Identifiable {
        case now, twoMinutes, fifteenMinutes, oneHour, evening
        var id: Self { self }
        var title: String {
            switch self {
            case .now: return String(localized: "Now")
            case .twoMinutes: return String(localized: "In 2 minutes")
            case .fifteenMinutes: return String(localized: "In 15 minutes")
            case .oneHour: return String(localized: "In 1 hour")
            case .evening: return String(localized: "This evening (8:30 PM)")
            }
        }
        func due(from now: Date = Date()) -> Date? {
            switch self {
            case .now: return nil
            case .twoMinutes: return now.addingTimeInterval(120)
            case .fifteenMinutes: return now.addingTimeInterval(15 * 60)
            case .oneHour: return now.addingTimeInterval(3600)
            case .evening:
                return Calendar.current.nextDate(after: now, matching: DateComponents(hour: 20, minute: 30),
                                                 matchingPolicy: .nextTime)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Call me about") {
                    TextField("e.g. the deploy, my day tomorrow", text: $what, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("callMe.reason")
                }
                Section("When") {
                    Picker("When", selection: $when) {
                        ForEach(Timing.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if let result {
                    Section {
                        Label {
                            Text(verbatim: result)
                        } icon: {
                            Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(succeeded ? Color.green : Color.red)
                    }
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        if isSending { ProgressView().frame(maxWidth: .infinity) } else {
                            Text(succeeded ? "Done" : "Ask JARVIS to call").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSending || succeeded)
                    .accessibilityIdentifier("callMe.send")
                }
            }
            .navigationTitle("Call me back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(succeeded ? "Close" : "Cancel") { dismiss() } }
            }
        }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        let reason = what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "JARVIS check-in (from the app)" : what
        do {
            if let due = when.due() {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let reply = try await JarvisCallEndpoints.bridgeRequest(
                    "schedule", method: "POST",
                    body: ["at_iso": formatter.string(from: due), "reason": reason, "scheduled_by": "ios-v3-call-me"])
                result = String(localized: "Scheduled for \(CallsView.displayTime(reply["at"] as? String ?? formatter.string(from: due))).")
            } else {
                let reply = try await JarvisCallEndpoints.bridgeRequest(
                    "call", method: "POST", body: ["reason": reason, "scheduled_by": "ios-v3-call-me"])
                result = (reply["pushed"] as? Bool) == true
                    ? String(localized: "Ringing now.")
                    : String(localized: "The call was placed, but the ring push did not go out. Check the bridge health.")
            }
            succeeded = true
        } catch {
            result = error.localizedDescription
            succeeded = false
        }
    }
}
