import SwiftUI

/// Calls tab (backlog #4): "Call me" via bridge /call (Bearer auth now
/// accepted), live call state from CallManager, scheduled calls list/cancel.
struct CallsView: View {
    struct ScheduledCall: Identifiable, Decodable {
        let call_id: String
        let at_iso: String
        let reason: String
        let scheduled_by: String?
        var id: String { call_id }
    }

    /// One entry of the bridge's scheduler drop log (1k): a call the bridge
    /// GAVE UP on — 10 failed push attempts or a malformed entry — so it will
    /// never fire. Not an error state of THIS request; history that used to
    /// live only in container logs.
    struct DroppedCall: Identifiable, Decodable {
        let call_id: String
        let reason: String
        let at_iso: String
        let scheduled_by: String?
        let dropped_at: String
        let why: String
        var id: String { call_id }
    }

    @ObservedObject private var mgr = CallManager.shared
    // Persistent log (survives restarts; incoming pushes land here too).
    @ObservedObject private var callLog = CallLogStore.shared
    @State private var scheduled: [ScheduledCall] = []
    @State private var dropped: [DroppedCall] = []
    @State private var loadFailed = false
    @State private var calling = false
    @State private var status: String?
    @State private var showSchedule = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await mgr.placeDirectCall() }
                    } label: {
                        HStack {
                            Image(systemName: "phone.fill")
                                .foregroundStyle(Color.jarvisAccent)
                            Text(mgr.callState == "idle" ? "Talk to JARVIS" : mgr.callState.hasPrefix("failed") ? "Talk to JARVIS" : "Calling…")
                                .bold()
                            Spacer()
                        }
                    }
                    .disabled(mgr.activeCallUUID != nil)
                    if mgr.activeCallUUID != nil && mgr.callState != "idle" {
                        Button(role: .destructive) {
                            mgr.endActiveCall()
                        } label: {
                            Label("End call", systemImage: "phone.down.fill")
                        }
                    }
                    // Server-initiated ring: fires a VoIP push to this phone
                    // (needs the APNs p8 installed; until then the bridge
                    // queues it — kept for parity with the voice tools).
                    Button {
                        Task { await callMe() }
                    } label: {
                        HStack {
                            Image(systemName: "phone.badge.waveform")
                                .foregroundStyle(.secondary)
                            Text("Ring this phone (server push)")
                                .font(.callout)
                            Spacer()
                        }
                    }
                    .disabled(calling)
                    Button {
                        Haptics.tap()
                        showSchedule = true
                    } label: {
                        HStack {
                            Image(systemName: "calendar.badge.plus")
                                .foregroundStyle(Color.jarvisAccent)
                            Text("Schedule a call…")
                                .font(.callout)
                            Spacer()
                        }
                    }
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
                    if !mgr.sessionInfo.isEmpty {
                        Text(mgr.sessionInfo).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let said = mgr.lastTranscript {
                        Text("“\(said)”").font(.caption.italic())
                            .foregroundStyle(.secondary).lineLimit(3)
                    }
                } header: {
                    Text("Direct line")
                }

                Section("Call log") {
                    if callLog.entries.isEmpty {
                        Text("No calls yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(callLog.entries.reversed()) { c in
                        HStack {
                            Image(systemName: c.outgoing ? "arrow.up.right.phone" : "phone.fill")
                                .foregroundStyle(c.outcome == "missed" ? Color.red : Color.secondary)
                            VStack(alignment: .leading) {
                                Text(c.reason).font(.callout)
                                HStack(spacing: 5) {
                                    Text(c.at.formatted(date: .omitted, time: .shortened))
                                    if let d = c.durationSeconds, d > 0 {
                                        Text("· \(Self.dur(d))")
                                    }
                                    if let o = c.outcome, o != "ended" {
                                        Text("· \(o)").foregroundStyle(o == "answered" ? Color.green : Color.secondary)
                                    }
                                }
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    // Load failure ≠ empty schedule: a transient bridge outage
                    // must show the error, not the lie "Nothing scheduled."
                    // (Same fix SecretsView got — empty state only when the
                    // fetch SUCCEEDED and returned nothing.)
                    if scheduled.isEmpty && !loadFailed {
                        Text("Nothing scheduled.").font(.caption).foregroundStyle(.secondary)
                    }
                    if loadFailed && scheduled.isEmpty {
                        Label("Can't reach the bridge — scheduled calls NOT loaded.", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.red)
                    }
                    ForEach(scheduled) { s in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.reason).font(.callout)
                                Text(Self.whenLabel(s.at_iso)).font(.caption2).foregroundStyle(.secondary)
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

                Section {
                    // 1k: calls the bridge GAVE UP on (10 failed pushes /
                    // malformed entry) — they will never fire. This used to
                    // be invisible: the entry left the schedule, and only a
                    // container log line remembered it. "Never fired" must be
                    // readable, not discoverable by waiting for a call that
                    // never comes.
                    if !dropped.isEmpty {
                        Text("These calls were dropped by the bridge and NEVER fired.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(dropped) { d in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.reason.isEmpty ? "(no reason)" : d.reason)
                                .font(.callout)
                            Text("\(Self.whenLabel(d.at_iso)) — dropped \(Self.whenLabel(d.dropped_at))")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(d.why).font(.caption2).foregroundStyle(.red.opacity(0.8))
                        }
                    }
                } header: {
                    // The count is the headline; red only when non-empty.
                    Text(dropped.isEmpty ? "Dropped" : "Dropped (\(dropped.count))")
                        .foregroundStyle(dropped.isEmpty ? .secondary : .red)
                }
            }
            .navigationTitle("Calls")
            .refreshable { await loadScheduled() }
            .task { await loadScheduled() }
            .sheet(isPresented: $showSchedule) {
                ScheduleCallSheet { at, reason in
                    await scheduleCall(at: at, reason: reason)
                }
            }
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
            let entryID = callLog.add(reason: "JARVIS call (from iOS app)", outgoing: true)
            CallManager.shared.trackOutgoingLog(entryID: entryID)
            Haptics.success()
        } catch {
            status = "Call failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    /// 0:45 / 3:20 style duration label for the call log.
    private static func dur(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Raw ISO (or anything unparseable) → "Sep 20, 2026 10:00" for the list.
    static func whenLabel(_ iso: String) -> String {
        // The bridge stores whatever /schedule received (ISO-8601 with
        // +00:00 offset); the app always sends full internet-date-time.
        let parser = ISO8601DateFormatter()
        if let d = parser.date(from: iso) {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        // Tolerate fractional seconds, then give up and show the raw string.
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: iso) {
            return d.formatted(date: .abbreviated, time: .shortened)
        }
        return iso
    }

    @MainActor
    private func loadScheduled() async {
        // GET /schedule/list accepts the app's dashboard Bearer (_auth_dual),
        // same as every other call endpoint. 1k: the response also carries
        // `dropped` — the bridge's scheduler drop log.
        struct ListResp: Decodable {
            let scheduled: [ScheduledCall]
            var dropped: [DroppedCall]?
        }
        do {
            let resp = try await CCClient.shared.get(
                ServerConfig.shared.config.bridgeBaseURL + "/schedule/list",
                as: ListResp.self)
            scheduled = resp.scheduled
            dropped = resp.dropped ?? []
            loadFailed = false
        } catch {
            // Keep last-known-good entries: a transient bridge outage must not
            // look like "Nothing scheduled" (same contract as SecretsView).
            loadFailed = true
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
                status = "Scheduled call cancelled."
                Haptics.success()
            } else {
                // cancelled:0 = the call was already cancelled/fired elsewhere
                // (another device, the scheduler itself). Not an error, but a
                // silent no-op left the stale row visible forever — reconcile
                // with the server list and say what happened.
                await loadScheduled()
                if scheduled.contains(where: { $0.call_id == id }) {
                    status = "Bridge didn't cancel that call — try again."
                    Haptics.error()
                } else {
                    status = "Already cancelled (or already fired) — list refreshed."
                    Haptics.tap()
                }
            }
        } catch CCClient.Failure(let message) where message == "HTTP 404" {
            // Bridge 1j: an id that matches nothing 404s loudly (it used to
            // return cancelled:0). Same UX as the race: the row is stale —
            // refresh the list and say so.
            await loadScheduled()
            status = "Already cancelled (or already fired) — list refreshed."
            Haptics.tap()
        } catch {
            status = "Cancel failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    /// "Schedule a call…": POST /schedule on the bridge. The bridge's internal
    /// scheduler fires the VoIP push when due (20s tick). The device token is
    /// snapshotted server-side from the launch-time /register, so nothing
    /// device-specific goes up here.
    @MainActor
    private func scheduleCall(at: Date, reason: String) async {
        status = nil
        do {
            // Clamp: a sheet left open past the chosen moment would schedule a
            // call in the past (bridge fires immediately or rejects).
            let at = max(at, Date().addingTimeInterval(60))
            let iso = ISO8601DateFormatter().string(from: at)
            struct SchedResp: Decodable { let call_id: String; let at: String }
            let resp = try await CCClient.shared.post(
                ServerConfig.shared.config.bridgeBaseURL + "/schedule",
                body: ["at_iso": iso, "reason": reason, "scheduled_by": "ios-app"],
                as: SchedResp.self)
            scheduled.append(ScheduledCall(call_id: resp.call_id, at_iso: resp.at, reason: reason, scheduled_by: "ios-app"))
            status = "Scheduled for \(at.formatted(date: .abbreviated, time: .shortened))."
            Haptics.success()
            showSchedule = false
        } catch {
            status = "Scheduling failed: \(error.localizedDescription)"
            Haptics.error()
        }
    }
}

/// Composer for scheduling a future call: date+time picker + reason.
struct ScheduleCallSheet: View {
    var onSchedule: (Date, String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var when = Date().addingTimeInterval(3600)
    @State private var reason = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Call at", selection: $when, in: Date()...)
                }
                Section("Reason") {
                    TextField("What should JARVIS call about?", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                    // Bridge 400s an oversized reason (1g text guard): the
                    // reason rides the APNs payload and Apple rejects
                    // payloads over 4096 bytes, so stop the composer here.
                    if reason.utf8.count > 3500 {
                        Text("Too long: \(reason.utf8.count)/3500 bytes — the call would be rejected at push time.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    // /schedule expects ISO-8601; keep the picker honest.
                    LabeledContent("Will fire at", value: when.formatted(date: .long, time: .standard))
                        .font(.caption)
                } footer: {
                    Text("The bridge rings this phone via VoIP push when the time comes. Requires the APNs key to be installed.")
                }
                .onAppear {
                    // Default lands in the past if the sheet sits open a
                    // while (or re-opens after time passed): clamp forward.
                    if when < Date() { when = Date().addingTimeInterval(3600) }
                }
            }
            .navigationTitle("Schedule call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Schedule") {
                            guard reason.utf8.count <= 3500 else { return }
                            busy = true
                            Task {
                                await onSchedule(when, reason.trimmingCharacters(in: .whitespaces))
                                busy = false
                            }
                        }
                        .disabled(reason.isEmpty || reason.utf8.count > 3500)
                    }
                }
            }
        }
    }
}

struct CallResp: Decodable { let call_id: String; let pushed: Bool }
struct CancelResp: Decodable { let cancelled: Int? }
