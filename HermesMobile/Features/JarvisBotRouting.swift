import Foundation

/// JARVIS's specialists are Bots: one Hermes Profile per domain (iOS Builder first), each
/// knowing only its own. A new chat on the general Profile asks the box which Bot its first
/// message belongs to and, when one claims it, opens the chat in that Bot before the message
/// goes out (`docs/agents/bots.md` § Bot routing). Nothing else moves: a chat opened in a Bot,
/// or in a Profile the user picked, stays where it is.
struct JarvisBotRoute: Decodable, Equatable, Sendable {
    /// The Profile that should own the message, or `general`.
    let profile: String
    let confidence: Double
    let reason: String?
    /// The Bot's title ("iOS Builder"); nil for general.
    let title: String?
}

enum JarvisBotRouting {
    /// The box's general Profile, the only one whose new chats are routed.
    static let generalProfile = "default"
    /// A guess below this keeps the chat general.
    static let minimumConfidence = 0.7
    /// The first message waits at most this long for the box, then goes out as general. The
    /// box answers in two to five seconds (both classifiers run at once, keywords as a fallback).
    static let timeout: Duration = .seconds(8)

    static func routes(profile: String) -> Bool { profile == generalProfile }

    /// The push bridge that answers `/bridge/route` is the JARVIS host. A Debug build pointed
    /// at `scripts/local-hermes` (the Maestro runner) has no bridge, and waiting on it only
    /// delays the first message. Release builds always use the production address.
    static func asksTheBox(at url: URL) -> Bool {
        url.host?.caseInsensitiveCompare(JarvisServer.productionAddress.host ?? "") == .orderedSame
    }

    /// The Bot `reply` moves the chat to, or nil: no reply, a general or low-confidence one, or
    /// the Profile the chat is already on.
    static func destination(_ reply: JarvisBotRoute?, current: String) -> String? {
        guard let reply else { return nil }
        let profile = reply.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty, profile != "general", profile != current,
              reply.confidence >= minimumConfidence else { return nil }
        return profile
    }

    /// The notice the moved chat opens with: the Bot's title, else its Profile name.
    static func notice(for reply: JarvisBotRoute, profile: String) -> String {
        let title = reply.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(localized: "Opened in \(title.isEmpty ? profile : title)")
    }
}

/// `POST /bridge/route` on the JARVIS push bridge, signed with the app's native Bearer
/// (`JarvisVoiceAuth`). Any failure, the timeout included, is no route: the chat stays general.
@MainActor
enum JarvisBotRouter {
    static func route(_ text: String, current: String) async -> JarvisBotRoute? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, JarvisBotRouting.asksTheBox(at: JarvisServer.address) else { return nil }
        do {
            return try await withTimeout(JarvisBotRouting.timeout) { try await request(trimmed, current: current) }
        } catch {
            JarvisClientLog.record("route", "no route (\(type(of: error))); the chat stays on \(current)", path: "/bridge/route")
            return nil
        }
    }

    private static func request(_ text: String, current: String) async throws -> JarvisBotRoute {
        let token = try await JarvisVoiceAuth.shared.validAccessToken()
        var request = URLRequest(postTo: JarvisServer.address.appendingPathComponent("bridge/route"))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "profile": current])
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(JarvisBotRoute.self, from: data)
    }

    private static func withTimeout<T: Sendable>(_ limit: Duration,
                                                 _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }
}
