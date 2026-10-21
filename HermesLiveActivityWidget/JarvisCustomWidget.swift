import AppIntents
import SwiftUI
import WidgetKit

/// Home-screen widgets JARVIS designed in a chat (requirement 8). Each widget on the home screen
/// shows one saved spec (`JarvisWidgetStore`), picked in the widget's Edit Widget sheet; with
/// none picked it shows the newest. The app redraws them when a spec or its live data changes.
struct JarvisCustomWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: JarvisWidgetSpec.widgetKind, intent: SelectJarvisWidgetIntent.self,
                               provider: JarvisWidgetProvider()) { entry in
            JarvisWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("JARVIS")
        .description("A widget JARVIS designed for you in a chat.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct JarvisWidgetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "JARVIS Widget"
    static var defaultQuery = JarvisWidgetQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct JarvisWidgetQuery: EntityQuery {
    func entities(for identifiers: [JarvisWidgetEntity.ID]) async throws -> [JarvisWidgetEntity] {
        JarvisWidgetStore.all().filter { identifiers.contains($0.id) }.map(Self.entity)
    }

    func suggestedEntities() async throws -> [JarvisWidgetEntity] {
        JarvisWidgetStore.all().reversed().map(Self.entity)
    }

    func defaultResult() async -> JarvisWidgetEntity? {
        JarvisWidgetStore.all().last.map(Self.entity)
    }

    private static func entity(_ spec: JarvisWidgetSpec) -> JarvisWidgetEntity {
        JarvisWidgetEntity(id: spec.id, title: spec.title)
    }
}

struct SelectJarvisWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "JARVIS Widget"
    static var description = IntentDescription("Choose which of JARVIS's widgets to show.")

    @Parameter(title: "Widget")
    var widget: JarvisWidgetEntity?
}

struct JarvisWidgetEntry: TimelineEntry {
    let date: Date
    let spec: JarvisWidgetSpec?
}

struct JarvisWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> JarvisWidgetEntry {
        JarvisWidgetEntry(date: Date(), spec: Self.sample)
    }

    func snapshot(for configuration: SelectJarvisWidgetIntent, in context: Context) async -> JarvisWidgetEntry {
        JarvisWidgetEntry(date: Date(), spec: Self.spec(for: configuration) ?? Self.sample)
    }

    func timeline(for configuration: SelectJarvisWidgetIntent, in context: Context) async -> Timeline<JarvisWidgetEntry> {
        // The app reloads the timeline whenever it saves a spec or refreshes its data; the
        // periodic reload only picks up a spec saved while the widget wasn't asked.
        Timeline(entries: [JarvisWidgetEntry(date: Date(), spec: Self.spec(for: configuration))],
                 policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private static func spec(for configuration: SelectJarvisWidgetIntent) -> JarvisWidgetSpec? {
        let saved = JarvisWidgetStore.all()
        if let id = configuration.widget?.id, let spec = saved.first(where: { $0.id == id }) { return spec }
        return saved.last
    }

    static let sample = JarvisWidgetSpec(
        id: "sample", title: "Orders today", subtitle: "Ask JARVIS to design one", symbol: "sparkles",
        accent: nil, style: .metric, value: "42", caption: "orders", trend: "+12%", rows: nil, points: nil,
        data: nil, updated: nil)
}

struct JarvisWidgetEntryView: View {
    let entry: JarvisWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let spec = entry.spec {
            JarvisWidgetContentView(spec: spec, size: size)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Color(red: 0x3F / 255, green: 0xD6 / 255, blue: 0xF5 / 255))
                Text("No JARVIS widgets yet")
                    .font(.caption.weight(.semibold))
                Text("Describe a widget to JARVIS in a chat, then tap Add to Home Screen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var size: JarvisWidgetContentView.Size {
        switch family {
        case .systemMedium: return .medium
        case .systemLarge, .systemExtraLarge: return .large
        default: return .small
        }
    }
}
