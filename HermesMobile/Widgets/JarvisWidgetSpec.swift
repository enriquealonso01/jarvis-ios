import Foundation
import Security
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// A home-screen widget JARVIS designed in a chat (requirement 8). JARVIS replies with a fenced
/// ```jarvis-widget block holding one spec; the app shows a preview with Add to Home Screen, and
/// the JARVIS widget (HermesLiveActivityWidget's `JarvisCustomWidget`) draws the saved specs.
/// This file is compiled into the app and the widget extension.
///
/// Live data: a spec may name `data`, a JSON file on the host (normally under
/// ~/JARVIS-Files/widgets/) that JARVIS keeps current, for example from a cron job. Its fields
/// (`value`, `caption`, `trend`, `rows`, `points`, `updated`) replace the spec's own each time
/// the app refreshes the widgets.
struct JarvisWidgetSpec: Codable, Equatable, Identifiable, Sendable {
    enum Style: String, Codable, Sendable {
        case metric, list, chart
    }

    struct Row: Codable, Equatable, Hashable, Sendable {
        var label: String
        var value: String
    }

    struct Point: Codable, Equatable, Hashable, Sendable {
        var label: String
        var value: Double
    }

    /// Stable: a spec with the same id replaces the saved one.
    var id: String
    var title: String
    var subtitle: String?
    /// An SF Symbol name.
    var symbol: String?
    /// `#RRGGBB`; Jarvis Cyan when absent or unreadable.
    var accent: String?
    var style: Style
    var value: String?
    var caption: String?
    var trend: String?
    var rows: [Row]?
    var points: [Point]?
    /// A host path whose JSON refreshes the fields above.
    var data: String?
    /// When the data was last refreshed (ISO 8601 from the data file, or the app's refresh time).
    var updated: String?

    static let fenceMarker = "jarvis-widget"
    static let widgetKind = "JarvisCustomWidget"

    /// The one spec in a ```jarvis-widget fence (or bare JSON), or nil when it doesn't parse or
    /// has no id or title. Lenient about unknown fields and a missing style (metric).
    static func parse(_ raw: String) -> JarvisWidgetSpec? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            guard let firstNewline = body.firstIndex(of: "\n") else { return nil }
            body = String(body[body.index(after: firstNewline)...])
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
        }
        guard let data = body.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if object["style"] == nil { object["style"] = Style.metric.rawValue }
        if let value = object["value"], !(value is String) { object["value"] = "\(value)" }
        guard let normalized = try? JSONSerialization.data(withJSONObject: object),
              var spec = try? JSONDecoder().decode(JarvisWidgetSpec.self, from: normalized) else { return nil }
        spec.id = spec.id.trimmingCharacters(in: .whitespacesAndNewlines)
        spec.title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.id.isEmpty, !spec.title.isEmpty else { return nil }
        return spec
    }

    /// This spec with a data file's fields laid over it.
    func applying(dataFile json: Data, refreshedAt now: Date = Date()) -> JarvisWidgetSpec {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return self }
        var spec = self
        if let value = object["value"] { spec.value = value as? String ?? "\(value)" }
        if let caption = object["caption"] as? String { spec.caption = caption }
        if let trend = object["trend"] as? String { spec.trend = trend }
        if let title = object["title"] as? String, !title.isEmpty { spec.title = title }
        if let rows = object["rows"], let data = try? JSONSerialization.data(withJSONObject: rows),
           let decoded = try? JSONDecoder().decode([Row].self, from: data) { spec.rows = decoded }
        if let points = object["points"], let data = try? JSONSerialization.data(withJSONObject: points),
           let decoded = try? JSONDecoder().decode([Point].self, from: data) { spec.points = decoded }
        spec.updated = object["updated"] as? String ?? ISO8601DateFormatter().string(from: now)
        return spec
    }

    var accentColor: Color {
        guard let accent, let color = Color(jarvisWidgetHex: accent) else {
            return Color(red: 0x3F / 255, green: 0xD6 / 255, blue: 0xF5 / 255)
        }
        return color
    }
}

extension Color {
    init?(jarvisWidgetHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// The saved widget specs, in one generic-password item in the keychain group the app shares
/// with its extensions (`HermesKeychainAccessGroup`). The keychain rather than the App Group,
/// because every provisioning profile grants the team's keychain groups while the App Group must
/// be attached by hand in the developer portal. Readable after first unlock, so the widget can
/// draw on a locked phone. Specs hold no secrets.
enum JarvisWidgetStore {
    static let service = "com.enriquecodes.jarvis.widgets"
    static let account = "specs"
    /// The most widgets kept; the oldest go first.
    static let limit = 20

    static func all(bundle: Bundle = .main) -> [JarvisWidgetSpec] {
        for group in accessGroups(bundle) {
            var query = baseQuery(group)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
                return (try? JSONDecoder().decode([JarvisWidgetSpec].self, from: data)) ?? []
            }
        }
        return []
    }

    static func spec(id: String, bundle: Bundle = .main) -> JarvisWidgetSpec? {
        all(bundle: bundle).first { $0.id == id }
    }

    /// Adds the spec, or replaces the saved one with its id, and redraws the widgets.
    @discardableResult
    static func save(_ spec: JarvisWidgetSpec, bundle: Bundle = .main) -> Bool {
        var specs = all(bundle: bundle).filter { $0.id != spec.id }
        specs.append(spec)
        if specs.count > limit { specs.removeFirst(specs.count - limit) }
        return write(specs, bundle: bundle)
    }

    @discardableResult
    static func remove(id: String, bundle: Bundle = .main) -> Bool {
        write(all(bundle: bundle).filter { $0.id != id }, bundle: bundle)
    }

    @discardableResult
    static func write(_ specs: [JarvisWidgetSpec], bundle: Bundle = .main) -> Bool {
        guard let data = try? JSONEncoder().encode(specs) else { return false }
        for group in accessGroups(bundle) {
            let query = baseQuery(group)
            let attributes: [CFString: Any] = [kSecValueData: data,
                                               kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add.merge(attributes) { $1 }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            if status == errSecSuccess {
                reloadWidgets()
                return true
            }
        }
        return false
    }

    static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: JarvisWidgetSpec.widgetKind)
        #endif
    }

    /// The shared group first; with no group (a test host, an unsigned build) the process's own.
    private static func accessGroups(_ bundle: Bundle) -> [String?] {
        let group = (bundle.object(forInfoDictionaryKey: "HermesKeychainAccessGroup") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        return group.map { [$0, nil] } ?? [nil]
    }

    private static func baseQuery(_ group: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrService: service, kSecAttrAccount: account]
        if let group { query[kSecAttrAccessGroup] = group }
        return query
    }
}

/// How a widget spec looks, in the widget and in the chat preview.
struct JarvisWidgetContentView: View {
    enum Size { case small, medium, large }

    let spec: JarvisWidgetSpec
    var size: Size = .small

    var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 4 : 6) {
            header
            switch spec.style {
            case .metric: metric
            case .list: list
            case .chart: chart
            }
            Spacer(minLength: 0)
            if let updated = spec.updated, size != .small {
                Text(verbatim: Self.updatedText(updated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let symbol = spec.symbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(spec.accentColor)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: spec.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = spec.subtitle, !subtitle.isEmpty, size != .small {
                    Text(verbatim: subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var metric: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: spec.value ?? "–")
                .font(.system(size: size == .small ? 34 : 40, weight: .bold, design: .rounded))
                .foregroundStyle(spec.accentColor)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let caption = spec.caption, !caption.isEmpty {
                    Text(verbatim: caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let trend = spec.trend, !trend.isEmpty {
                    Text(verbatim: trend)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(trend.hasPrefix("-") ? Color.red : Color.green)
                }
            }
        }
    }

    private var list: some View {
        let rows = Array((spec.rows ?? []).prefix(size == .large ? 8 : (size == .medium ? 4 : 3)))
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.self) { row in
                HStack {
                    Text(verbatim: row.label).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: row.value).font(.caption.weight(.semibold)).foregroundStyle(spec.accentColor)
                        .lineLimit(1)
                }
            }
        }
    }

    private var chart: some View {
        let points = Array((spec.points ?? []).suffix(size == .small ? 7 : 12))
        let top = max(points.map(\.value).max() ?? 1, 0.000_1)
        return VStack(alignment: .leading, spacing: 4) {
            if let value = spec.value {
                Text(verbatim: value).font(.title3.weight(.bold)).foregroundStyle(spec.accentColor).lineLimit(1)
            }
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(spec.accentColor.opacity(0.85))
                            .frame(height: max(2, proxy.size.height * max(point.value, 0) / top))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            if size != .small, let first = points.first?.label, let last = points.last?.label {
                HStack {
                    Text(verbatim: first)
                    Spacer()
                    Text(verbatim: last)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    static func updatedText(_ updated: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: updated) else { return updated }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
