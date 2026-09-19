import SwiftUI

/// Home tab: the CC summary — vitals, gateway, LLM usage, current work,
/// automations. Same endpoints the web Control Center polls.
struct HomeView: View {
    @State private var vitals: Vitals?
    @State private var zai: ZaiUsage?
    @State private var autos: Automations?
    @State private var activity: Activity?
    @State private var attention: Attention?
    @State private var bridge: Overview.Bridge?
    @State private var bridgeHealth: BridgeHealth?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let error {
                        GlassCard {
                            VStack(spacing: 8) {
                                Label(error, systemImage: "wifi.exclamationmark")
                                    .font(.footnote)
                                Button("Retry") {
                                    Haptics.tap()
                                    Task { await load() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    if hasAlerts { alertsCard }
                    statusCard
                    llmCard
                    cronsCard
                    currentWorkCard
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .background(Color.black)
            .navigationTitle("JARVIS")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    /// Failed tasks, waiting sessions, failing automations — same feed the web
    /// CC banner shows. Hidden entirely when nothing needs attention.
    private var hasAlerts: Bool { (attention?.count ?? 0) > 0 }

    private var alertsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("ATTENTION", icon: "exclamationmark.triangle.fill")
                ForEach(attention?.alerts ?? [], id: \.refKey) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(a.severity == "crit" ? Color.red : Color.yellow)
                                .frame(width: 7, height: 7)
                            Text(a.title).font(.caption).lineLimit(1)
                        }
                        if let msg = a.msg, !msg.isEmpty {
                            Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("SYSTEM", icon: "cpu")
                HStack(spacing: 18) {
                    metric("CPU", value: vitals?.cpu_pct.map { "\(Int($0))%" } ?? "—")
                    metric("MEM", value: memLabel)
                    metric("DISK", value: diskLabel)
                }
                HStack(spacing: 6) {
                    Circle().fill(gatewayOK ? .green : .red).frame(width: 7, height: 7)
                    Text(gatewayOK ? "Gateway connected" : "Gateway unreachable")
                        .font(.caption).foregroundStyle(.secondary)
                    if bridgeHealth?.apns_configured == false {
                        // VoIP pushes queue server-side until the APNs p8 is
                        // installed (docs/BUILD.md) — visible, not silent.
                        Text("· ring pending APNs setup")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let lpe = bridgeHealth?.last_push_error, !lpe.isEmpty {
                        // Last APNs rejection, surfaced from the bridge
                        // (LAST_PUSH_ERROR written by _send_voip on any
                        // non-200). "403 InvalidProviderToken" means the
                        // installed .p8 lacks the APNs capability — swap it
                        // (scripts/swap_apns_key.py, docs/BUILD.md).
                        Text("· APNs: \(lpe)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let dc = bridgeHealth?.dropped_calls, dc > 0 {
                        // 1k: the bridge gave up on scheduled calls (dead
                        // token / broken key when they came due). Visible
                        // here; the full log lives on the Calls tab.
                        Text("· \(dc) scheduled call\(dc == 1 ? "" : "s") dropped")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    if bridgeHealth?.device_registered == false {
                        // This phone hasn't completed /register yet (fresh
                        // install, or push woke us before login). Server-side
                        // "call me" can't reach us until it lands — visible.
                        Text("· device not registered")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(uptimeLabel).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var llmCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("LLM USAGE", icon: "bolt.fill")
                if let windows = zai?.windows, !windows.isEmpty {
                    ForEach(windows, id: \.key) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(w.label.capitalized).font(.caption)
                                Spacer()
                                Text("\(w.used ?? 0) / \(w.limit ?? 0)").font(.caption.monospacedDigit())
                            }
                            ProgressView(value: min(1.0, (w.percent ?? 0) / 100.0))
                                .tint(.jarvisAccent)
                        }
                    }
                } else {
                    Text(zai?.error ?? "Usage unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cronsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("CRONS", icon: "clock.badge.checkmark")
                let failing = autos?.failing ?? 0
                HStack {
                    Text("\(autos?.active ?? 0) active").font(.subheadline)
                    if failing > 0 {
                        Text("\(failing) failing").font(.subheadline).foregroundStyle(.red)
                    }
                    Spacer()
                }
                ForEach((autos?.items ?? []).prefix(4), id: \.name) { item in
                    HStack {
                        Circle()
                            .fill(item.status == "failing" ? .red : .green)
                            .frame(width: 6, height: 6)
                        Text(item.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(nextIn(item.next_seconds)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var currentWorkCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("CURRENT WORK", icon: "hammer.fill")
                let sessions = (activity?.sessions ?? []).prefix(3)
                if sessions.isEmpty {
                    Text("Nothing in flight.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(sessions), id: \.id) { s in
                    NavigationLink {
                        WorkThreadView(workId: s.id, title: s.title ?? "Work")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title ?? "Untitled").font(.caption).lineLimit(2)
                                .foregroundStyle(.primary)
                            HStack {
                                Text(s.source ?? "").font(.caption2).foregroundStyle(Color.jarvisAccent)
                                if let ago = s.ago_seconds {
                                    Text("· \(Self.ago(ago))").font(.caption2).foregroundStyle(.secondary)
                                }
                                if s.active == true {
                                    Text("· LIVE").font(.caption2.bold()).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func cardHeader(_ title: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.caption.bold())
                .foregroundStyle(Color.jarvisAccent)
                .tracking(1.2)
            Spacer()
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var memLabel: String {
        guard let used = vitals?.mem_used_mb, let total = vitals?.mem_total_mb else { return "—" }
        return "\(used / 1024)/\(total / 1024)G"
    }

    private var diskLabel: String {
        guard let used = vitals?.disk_used_gb, let total = vitals?.disk_total_gb else { return "—" }
        return "\(used)/\(total)G"
    }

    private var uptimeLabel: String {
        guard let up = vitals?.uptime_seconds else { return "" }
        let d = up / 86400
        return "up \(d)d"
    }

    /// Gateway connectivity = PC-bridge reachability reported by the CC
    /// overview (`/api/control/overview` → bridge.reachable, cached 60s
    /// server-side). Optimistic when unknown: a red dot needs evidence.
    private var gatewayOK: Bool { bridge?.reachable ?? true }

    private func nextIn(_ secs: Int?) -> String {
        guard let secs else { return "" }
        if secs < 90 { return "\(secs)s" }
        if secs < 5400 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }

    static func ago(_ secs: Int) -> String {
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    @MainActor
    private func load() async {
        // Per-endpoint resilience: each card loads independently, so one
        // failing endpoint (e.g. a transient zai_usage 500) can't blank the
        // whole Home tab or discard fresh data from the other four.
        func load1<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
            try await CCClient.shared.get(path, as: type)
        }
        async let v: Vitals? = try? load1("/api/control/vitals", as: Vitals.self)
        async let o: Overview? = try? load1("/api/control/overview", as: Overview.self)
        async let z: ZaiUsage? = try? load1("/api/control/zai_usage", as: ZaiUsage.self)
        async let a: Automations? = try? load1("/api/control/automations", as: Automations.self)
        async let w: Activity? = try? load1("/api/control/activity", as: Activity.self)
        async let at: Attention? = try? load1("/api/control/attention", as: Attention.self)
        async let bh: BridgeHealth? = try? load1(
            ServerConfig.shared.config.bridgeBaseURL + "/health", as: BridgeHealth.self)
        let (v2, o2, z2, a2, w2, at2, bh2) = await (v, o, z, a, w, at, bh)
        vitals = v2 ?? vitals
        bridge = o2?.bridge ?? bridge
        zai = z2 ?? zai
        autos = a2 ?? autos
        activity = w2 ?? activity
        attention = at2 ?? attention
        bridgeHealth = bh2 ?? bridgeHealth
        // Only surface the error card when EVERYTHING failed (dashboard truly
        // unreachable / not signed in) — a single dead endpoint just keeps
        // its last-known-good card.
        error = (vitals == nil && zai == nil && autos == nil && activity == nil && attention == nil && bridge == nil)
            ? "Can't reach the dashboard." : nil
    }
}
