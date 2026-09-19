import Foundation

/// Typed client for the dashboard Control Center API. Bearer-authed,
/// auto-refreshes on 401, decodes the real CC payload shapes.
/// MainActor-isolated: every call site is a SwiftUI view/task on the main
/// actor, and the token/refresh bookkeeping reads AuthStore.shared (itself
/// MainActor-isolated), so that's the correct isolation domain.
@MainActor
final class CCClient: @unchecked Sendable {
    static let shared = CCClient()

    struct Failure: Error { let message: String }

    private var inFlightRefresh: Task<Bool, Never>?

    private func base() -> String {
        ServerConfig.shared.config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private func urlFor(_ path: String) -> URL? {
        // Absolute URLs (e.g. the push-bridge origin) pass through as-is;
        // relative paths get the dashboard base prepended.
        if path.lowercased().hasPrefix("http://") || path.lowercased().hasPrefix("https://") {
            return URL(string: path)
        }
        return URL(string: base() + path)
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = urlFor(path) else { throw Failure(message: "bad server URL") }
        var data = try await rawGet(url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let err as CCClient.Failure {
            throw err
        } catch {
            // 401 bodies decode as our error shape — attempt one refresh+retry.
            if await refreshIfNeeded() {
                data = try await rawGet(url)
                return try JSONDecoder().decode(T.self, from: data)
            }
            throw Failure(message: "Request failed: \(error.localizedDescription)")
        }
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        guard let url = urlFor(path) else { throw Failure(message: "bad server URL") }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw Failure(message: "bad request body")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        let data = try await authedSend(req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rawGet(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await authedSend(req)
    }

    private func authedSend(_ req: URLRequest) async throws -> Data {
        guard let token = AuthStore.shared.accessToken else {
            throw Failure(message: "not signed in")
        }
        var req = req
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw Failure(message: "no response")
        }
        if http.statusCode == 401, await refreshIfNeeded() {
            req.setValue("Bearer \(AuthStore.shared.accessToken ?? token)", forHTTPHeaderField: "Authorization")
            let (data2, resp2) = try await URLSession.shared.data(for: req)
            guard (resp2 as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure(message: "unauthorized")
            }
            return data2
        }
        guard (200...299).contains(http.statusCode) else {
            throw Failure(message: "HTTP \(http.statusCode)")
        }
        return data
    }

    private func refreshIfNeeded() async -> Bool {
        guard AuthStore.shared.isExpiringSoon || AuthStore.shared.accessToken != nil else { return false }
        if let inFlight = inFlightRefresh {
            return await inFlight.value
        }
        let task = Task<Bool, Never> { await AuthStore.shared.refresh() }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }
}

// MARK: - CC response models (match hermes_cli/web_routers/control_center.py)

struct Vitals: Decodable {
    let cpu_pct: Double?
    let mem_used_mb: Int?
    let mem_total_mb: Int?
    let disk_used_gb: Int?
    let disk_total_gb: Int?
    let uptime_seconds: Int?
    let load: [Double]?
    let nproc: Int?
}

struct Overview: Decodable {
    struct Bridge: Decodable {
        let configured: Bool?
        let reachable: Bool?
        let latency_ms: Double?
    }
    struct Project: Decodable {
        let name: String
        let domain: String?
        // flexible: keep raw for anything else
        let description: String?
    }
    let generated_at: String
    let bridge: Bridge?
    let projects: [Project]?
}

/// The push bridge's own health (GET /health): apns_configured tells us
/// whether VoIP pushes can actually ring the phone, device_registered whether
/// THIS phone completed its /register handshake — both surfaced on Home.
struct BridgeHealth: Decodable {
    let ok: Bool?
    let apns_configured: Bool?
    let device_registered: Bool?
    /// Last APNs rejection recorded by the bridge ("403 InvalidProviderToken
    /// at …" when the installed .p8 can't sign pushes). Empty = healthy.
    let last_push_error: String?
    /// Scheduler drop log count (1k): scheduled calls the bridge GAVE UP on
    /// (10 failed pushes / malformed entry) still in its log. 0 = none
    /// recorded; the entries themselves are listed on the Calls tab.
    let dropped_calls: Int?
    let scheduled: Int?
}

struct ZaiUsage: Decodable {
    struct Window: Decodable {
        let key: String
        let label: String
        let used: Int?
        let limit: Int?
        let remaining: Int?
        let percent: Double?
        let reset_in_seconds: Int?
    }
    let available: Bool
    let level: String?
    let windows: [Window]
    let error: String?
}

struct Automations: Decodable {
    struct Item: Decodable {
        let name: String
        let domain: String?
        let cadence: String?
        let status: String?
        let next_seconds: Int?
        let last_status: String?
    }
    let available: Bool
    let items: [Item]
    let active: Int?
    let failing: Int?
}

struct Activity: Decodable {
    struct Session: Decodable {
        let id: String
        let title: String?
        let source: String?
        let model: String?
        let messages: Int?
        let ago_seconds: Int?
        let active: Bool?
    }
    let available: Bool
    let sessions: [Session]?
}

struct WorkChatReply: Decodable {
    let reply: String
}

/// GET /api/control/attention — failed tasks, waiting sessions, failing
/// automations (shape verified live: {alerts: [], count, critical};
/// alert = {severity: "crit"|"info", title, msg, kind, ref}).
struct Attention: Decodable {
    struct Alert: Decodable, Identifiable {
        let severity: String
        let title: String
        let msg: String?
        let kind: String?
        let ref: String?
        var id: String { ref ?? title }
        /// Stable ForEach identity even when ref is missing/empty.
        var refKey: String { ref.flatMap { $0.isEmpty ? nil : $0 } ?? "\(kind ?? "")|\(title)" }
    }
    let alerts: [Alert]
    let count: Int?
    let critical: Int?
}

struct WorkHistory: Decodable {
    struct Message: Decodable {
        let role: String
        let text: String?
        let ts: Double?
        let tool_name: String?
    }
    let available: Bool
    let session_id: String?
    let messages: [Message]?
    let total: Int?
}
