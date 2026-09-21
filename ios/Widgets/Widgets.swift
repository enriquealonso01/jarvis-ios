import SwiftUI
import Foundation
import WidgetKit

// JARVIS palette (mirrors JarvisApp.swift — separate target, no shared code).
extension Color {
    static let jarvisGold = Color(red: 1.0, green: 0.78, blue: 0.35)
}

// MARK: - Timeline plumbing

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot?
}

/// One provider serves all three widgets: a single fetch → cached-or-live
/// snapshot, refreshed at WidgetKit's cadence.
///
/// Swift 6 strict concurrency (iOS 18 SDK): the raw completion closure is not
/// Sendable, so capturing it straight into a Task fails with a "sending
/// parameter" data-race error (run 35622186018). The OnceBox wrapper is
/// @unchecked Sendable — each completion is called exactly once, from one
/// task, guarded by a lock — which is the sanctioned bridge between the
/// callback-based protocol and concurrent code.
private final class OnceBox<T>: @unchecked Sendable {
    private let fn: (T) -> Void
    private var done = false
    private let lock = NSLock()
    init(_ fn: @escaping (T) -> Void) { self.fn = fn }
    func call(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        fn(value)
    }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snap: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let box = OnceBox(completion)
        Task.detached {
            let live = await WidgetAPI.fetchLive()
            box.call(SnapshotEntry(date: Date(), snap: live ?? SharedStore.loadSnapshot()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let box = OnceBox(completion)
        Task.detached {
            let live = await WidgetAPI.fetchLive()
            if let live {
                SharedStore.saveSnapshot(live)
            }
            let entry = SnapshotEntry(date: Date(), snap: live ?? SharedStore.loadSnapshot())
            // WidgetKit enforces a ~15-minute reload floor; ask for 20 so
            // we sit comfortably above it. The app also re-kicks timelines
            // via WidgetCenter whenever Home refreshes.
            box.call(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(20 * 60))))
        }
    }
}

// MARK: - Status widget (quick actions + system status)

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot?

    var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .widgetURL(URL(string: "jarvis://status"))
        .containerBackground(for: .widget) { Color.black }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill((snap?.gatewayOK ?? true) ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text("JARVIS")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.jarvisGold)
            Spacer()
            Text(freshnessLabel)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var freshnessLabel: String {
        guard let snap else { return "" }
        let mins = Int(Date().timeIntervalSince1970 - snap.ts) / 60
        return mins < 1 ? "live" : "\(mins)m ago"
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let s = snap {
                row("CPU", "\(s.cpu)%")
                row("MEM", s.mem)
                row("DISK", s.disk)
                Spacer(minLength: 0)
                Text(s.gatewayOK ? "Gateway connected" : "Gateway unreachable")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Spacer(minLength: 0)
                Text("Open the app to sync")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                header
                if let s = snap {
                    row("CPU", "\(s.cpu)%")
                    row("MEM", s.mem)
                    row("DISK", s.disk)
                } else {
                    Text("No data yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("CURRENT WORK")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.jarvisGold)
                if let s = snap, !s.sessions.isEmpty {
                    ForEach(Array(s.sessions.prefix(2).enumerated()), id: \.offset) { _, sess in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sess.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                if sess.live {
                                    Text("LIVE")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.green)
                                }
                                Text(sess.ago)
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("Nothing in flight.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Link("Sessions", destination: URL(string: "jarvis://sessions")!)
                    Link("Calls", destination: URL(string: "jarvis://calls")!)
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.jarvisGold)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JarvisStatus", provider: SnapshotProvider()) { entry in
            StatusWidgetView(snap: entry.snap)
        }
        .configurationDisplayName("JARVIS Status")
        .description("Gateway, CPU, memory, disk and current work. The medium size adds quick links into Sessions and Calls.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Metrics widget (LLM usage + crons)

struct MetricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot?

    var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .widgetURL(URL(string: "jarvis://status"))
        .containerBackground(for: .widget) { Color.black }
    }

    private var cronsLine: String {
        guard let s = snap else { return "" }
        if s.cronsFailing > 0 {
            return "\(s.cronsActive) crons active · \(s.cronsFailing) failing"
        }
        return "\(s.cronsActive) crons active · all green"
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM USAGE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.jarvisGold)
            if let s = snap, let w = s.llm.first {
                HStack {
                    Text(w.label.capitalized)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(w.used) / \(w.limit)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                }
                ProgressView(value: min(max(w.pct, 0), 100), total: 100)
                    .tint(Color.jarvisGold)
                Spacer(minLength: 0)
                Text(cronsLine)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Spacer(minLength: 0)
                Text("Open the app to sync")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("LLM USAGE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.jarvisGold)
            if let s = snap, !s.llm.isEmpty {
                ForEach(Array(s.llm.prefix(3).enumerated()), id: \.offset) { _, w in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(w.label.capitalized)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(w.used) / \(w.limit)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                        }
                        ProgressView(value: min(max(w.pct, 0), 100), total: 100)
                            .tint(Color.jarvisGold)
                    }
                }
            } else {
                Text("Usage unavailable")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Divider()
            Text(cronsLine)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle((snap?.cronsFailing ?? 0) > 0 ? Color.red : Color.secondary)
                .lineLimit(1)
        }
    }
}

struct MetricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JarvisMetrics", provider: SnapshotProvider()) { entry in
            MetricsWidgetView(snap: entry.snap)
        }
        .configurationDisplayName("JARVIS Metrics")
        .description("LLM quota windows and automation health at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Alerts widget (attention feed)

struct AlertsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot?

    var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .widgetURL(URL(string: "jarvis://more"))
        .containerBackground(for: .widget) { Color.black }
    }

    private var clear: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.system(size: 22))
            Text("All clear")
                .font(.system(size: 11, weight: .semibold))
            Text("Nothing needs you.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ATTENTION")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.jarvisGold)
                Spacer()
            }
            if let s = snap, s.attentionCount > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(s.attentionCount)")
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(s.attentionCritical > 0 ? Color.red : Color.yellow)
                    Text(s.attentionCount == 1 ? "needs you" : "need you")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let first = s.alerts.first {
                    Text(first.title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            } else if snap != nil {
                clear
            } else {
                Spacer(minLength: 0)
                Text("Open the app to sync")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ATTENTION")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.jarvisGold)
                Spacer()
                if let s = snap, s.attentionCount > 0 {
                    Text("\(s.attentionCount) item\(s.attentionCount == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            if let s = snap, s.attentionCount > 0, !s.alerts.isEmpty {
                ForEach(Array(s.alerts.prefix(3).enumerated()), id: \.offset) { _, alert in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(alert.sev == "crit" ? Color.red : Color.yellow)
                                .frame(width: 6, height: 6)
                            Text(alert.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        if !alert.msg.isEmpty {
                            Text(alert.msg)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            } else if snap != nil {
                clear
            } else {
                Spacer(minLength: 0)
                Text("Open the app to sync")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AlertsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JarvisAlerts", provider: SnapshotProvider()) { entry in
            AlertsWidgetView(snap: entry.snap)
        }
        .configurationDisplayName("JARVIS Attention")
        .description("Failed tasks, waiting sessions and failing automations — the same feed as the Control Center banner.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Bundle

@main
struct JarvisWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        MetricsWidget()
        AlertsWidget()
    }
}
