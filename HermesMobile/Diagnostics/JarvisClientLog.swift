import Foundation
import UIKit

/// The app's side of "JARVIS can read all backend logs for the iOS app" (requirement 9): the
/// failures the phone sees (requests the host refused or never answered, calls, voice, push)
/// written to the host as one JSON Lines file per day, `~/.jarvis-ios/logs/<yyyy-MM-dd>.jsonl`,
/// where the jarvis-ios-logs skill reads them beside the server's own logs.
///
/// An entry holds a time, a category, the route's path (never its query, body, headers or
/// tokens) and a short reason (`HermesConnectionLog.reason`, no host text). The day's entries are
/// kept on the phone (the newest 500) and rewritten whole each time the app comes forward or
/// goes to the background, since the host's write route replaces a file rather than appending.
@MainActor
enum JarvisClientLog {
    struct Entry: Codable, Equatable {
        var ts: String
        var cat: String
        var msg: String
        var path: String?
        var build: String?
    }

    static let folder = "~/.jarvis-ios/logs"
    static let limit = 500
    private static let storeKey = "jarvis.clientLog.v1"
    private static var isDirty = false
    private static var isFlushing = false

    /// The User-Agent every Hermes request carries, so the server's access logs can tell the
    /// app's traffic apart: `JARVIS-iOS/3.0.0 (76; iOS 26.0)`.
    nonisolated static var userAgent: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "JARVIS-iOS/\(version) (\(build); iOS \(ProcessInfo.processInfo.operatingSystemVersionString))"
    }

    static func record(_ category: String, _ message: String, path: String? = nil, now: Date = Date(),
                       defaults: UserDefaults = .standard) {
        var entries = stored(defaults)
        entries.append(Entry(ts: ISO8601DateFormatter().string(from: now), cat: category,
                             msg: String(message.prefix(300)), path: path,
                             build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        save(entries, defaults)
        isDirty = true
    }

    /// A signed-in request that failed. Cancellations and the app's own log writes are left out.
    static func recordRequestFailure(_ request: URLRequest, _ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let path = request.url?.path ?? ""
        if path.hasSuffix("api/fs/write-text") || path.hasSuffix("api/files/mkdir") { return }
        record("http", "\(request.httpMethod ?? "GET") failed: \(HermesConnectionLog.reason(error))", path: path)
    }

    /// Today's entries as the file's text, one JSON object per line.
    static func fileText(for day: Date = Date(), defaults: UserDefaults = .standard) -> String {
        let prefix = dayString(day)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return stored(defaults).filter { $0.ts.hasPrefix(prefix) }
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    static func filePath(for day: Date = Date()) -> String {
        "\(folder)/\(dayString(day)).jsonl"
    }

    /// Writes today's file when something new was recorded since the last write.
    static func flush(server: URL, connection: BotConnection) async {
        guard isDirty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let text = fileText()
        guard !text.isEmpty else { isDirty = false; return }
        let http = HermesConnections.shared.connection(for: connection, server: server)
        let background = UIApplication.shared.beginBackgroundTask(withName: "jarvis.clientLog") {}
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        do {
            var written = try await http.reply(.fsWriteText(path: filePath(), content: text + "\n"))
            if written.status == 400 {
                _ = try await http.reply(.filesMkdir(path: folder))
                written = try await http.reply(.fsWriteText(path: filePath(), content: text + "\n"))
            }
            if (200..<300).contains(written.status) { isDirty = false }
        } catch {
            // Kept dirty: the next flush tries again.
        }
    }

    private static func dayString(_ date: Date) -> String {
        String(ISO8601DateFormatter().string(from: date).prefix(10))
    }

    private static func stored(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ entries: [Entry], _ defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: storeKey)
    }

    /// For tests.
    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storeKey)
        isDirty = false
    }
}
