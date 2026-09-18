import Foundation

/// Typed client for the dashboard Control Center API. Bearer-authed,
/// auto-refreshes on 401, decodes the real CC payload shapes.
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
        var data = try await rawGet(path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let err as CCClient.Failure {
            throw err
        } catch {
            // 401 bodies decode as our error shape — attempt one refresh+retry.
            if await refreshIfNeeded() {
                data = try await rawGet(path)
                return try JSONDecoder().decode(T.self, from: data)
            }
            throw Failure(message: "Request failed: \(error.localizedDescription)")
        }
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw Failure(message: "bad request body")
        }
        var req = URLRequest(url: urlFor(path)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        let data = try await authedSend(req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func rawGet(_ path: String) async throws -> Data {
        var req = URLRequest(url: urlFor(path)!)
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
        let live: Bool?
    }
    let available: Bool
    let sessions: [Session]?
}

struct WorkChatReply: Decodable {
    let reply: String
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
