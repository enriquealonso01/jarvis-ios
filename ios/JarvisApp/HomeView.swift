import SwiftUI

/// Home tab: the CC summary — vitals, gateway, LLM usage, current work,
/// automations. Same endpoints the web Control Center polls.
struct HomeView: View {
    @State private var vitals: Vitals?
    @State private var zai: ZaiUsage?
    @State private var autos: Automations?
    @State private var activity: Activity?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let error {
                        GlassCard { Label(error, systemImage: "wifi.exclamationmark").font(.footnote) }
                    }
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
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Gateway connected").font(.caption).foregroundStyle(.secondary)
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
                                Text(s.source ?? "").font(.caption2).foregroundStyle(.jarvisAccent)
                                if let ago = s.ago_seconds {
                                    Text("· \(Self.ago(ago))").font(.caption2).foregroundStyle(.secondary)
                                }
                                if s.live == true {
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
        do {
            async let v: Vitals = CCClient.shared.get("/api/control/vitals", as: Vitals.self)
            async let z: ZaiUsage = CCClient.shared.get("/api/control/zai_usage", as: ZaiUsage.self)
            async let a: Automations = CCClient.shared.get("/api/control/automations", as: Automations.self)
            async let w: Activity = CCClient.shared.get("/api/control/activity", as: Activity.self)
            let (v2, z2, a2, w2) = try await (v, z, a, w)
            vitals = v2; zai = z2; autos = a2; activity = w2
            error = nil
        } catch {
            self.error = "Can't reach the dashboard."
        }
    }
}
