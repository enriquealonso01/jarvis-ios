import Foundation

/// Data the app publishes into the shared app-group container.
/// MUST mirror the Codable shapes in ios/JarvisApp/WidgetBridge.swift — the
/// app writes, this target reads. Same JSON keys on both sides (explicit
/// snake_case CodingKeys); change them in BOTH files together.
struct WidgetSnapshot: Codable {
    struct LlmWindow: Codable {
        var label: String
        var used: Int
        var limit: Int
        var pct: Double
    }
    struct AlertItem: Codable {
        var sev: String
        var title: String
        var msg: String
    }
    struct SessionItem: Codable {
        var title: String
        var source: String
        var ago: String
        var live: Bool
    }

    var ts: TimeInterval
    var gatewayOK: Bool
    var cpu: Int
    var mem: String
    var disk: String
    var upDays: Int
    var llm: [LlmWindow]
    var cronsActive: Int
    var cronsFailing: Int
    var attentionCount: Int
    var attentionCritical: Int
    var alerts: [AlertItem]
    var sessions: [SessionItem]
    var deviceRegistered: Bool
    var apnsConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case ts
        case gatewayOK = "gateway_ok"
        case cpu, mem, disk
        case upDays = "up_days"
        case llm
        case cronsActive = "crons_active"
        case cronsFailing = "crons_failing"
        case attentionCount = "attention_count"
        case attentionCritical = "attention_critical"
        case alerts, sessions
        case deviceRegistered = "device_registered"
        case apnsConfigured = "apns_configured"
    }
}

/// Auth material the app mirrors into the group container so widgets can hit
/// the same dashboard API as the app (bearer + refresh tokens; the password
/// itself is never stored). Bearer-in-group-container tradeoff documented in
/// docs/WIDGETS.md.
struct WidgetAuth: Codable {
    var baseURL: String
    var bridgeURL: String
    var access: String
    var refresh: String
    var expiresAt: TimeInterval

    var isExpiringSoon: Bool {
        Date().timeIntervalSince1970 > expiresAt - 300
    }
}

enum SharedStore {
    static let groupID = "group.com.enriquecodes.jarvis"
    private static let snapshotKey = "jarvis.widget.snapshot.v1"
    private static let authKey = "jarvis.widget.auth.v1"

    /// nil when the app-group entitlement isn't on the installed build yet
    /// (pre-widget app version) — every caller degrades to "no data".
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: groupID)
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let d = defaults, let data = d.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func saveSnapshot(_ snap: WidgetSnapshot) {
        guard let d = defaults, let data = try? JSONEncoder().encode(snap) else { return }
        d.set(data, forKey: snapshotKey)
    }

    static func loadAuth() -> WidgetAuth? {
        guard let d = defaults, let data = d.data(forKey: authKey) else { return nil }
        return try? JSONDecoder().decode(WidgetAuth.self, from: data)
    }

    static func saveAuth(_ auth: WidgetAuth) {
        guard let d = defaults, let data = try? JSONEncoder().encode(auth) else { return }
        d.set(data, forKey: authKey)
    }
}

// MARK: - Live refresh (dashboard Control Center API, same shapes as the app)

private struct Vitals: Decodable {
    var cpu_pct: Double?
    var mem_used_mb: Int?
    var mem_total_mb: Int?
    var disk_used_gb: Int?
    var disk_total_gb: Int?
    var uptime_seconds: Int?
}

private struct Overview: Decodable {
    struct Bridge: Decodable { var reachable: Bool? }
    var bridge: Bridge?
}

private struct ZaiUsage: Decodable {
    struct Window: Decodable {
        var label: String
        var used: Int?
        var limit: Int?
        var percent: Double?
    }
    var windows: [Window]
}

private struct Automations: Decodable {
    var active: Int?
    var failing: Int?
}

private struct Attention: Decodable {
    struct Alert: Decodable {
        var severity: String
        var title: String
        var msg: String?
    }
    var alerts: [Alert]
    var count: Int?
    var critical: Int?
}

private struct Activity: Decodable {
    struct Session: Decodable {
        var title: String?
        var source: String?
        var ago_seconds: Int?
        var active: Bool?
    }
    var sessions: [Session]?
}

private struct BridgeHealth: Decodable {
    var apns_configured: Bool?
    var device_registered: Bool?
}

enum WidgetAPI {
    static func ago(_ secs: Int) -> String {
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    static func normalize(_ base: String) -> String {
        var b = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !b.lowercased().hasPrefix("https://") && !b.lowercased().hasPrefix("http://") {
            b = "https://" + b
        }
        return b
    }

    /// Live snapshot straight from the dashboard, or nil when offline /
    /// unauthenticated — callers fall back to the last published snapshot.
    static func fetchLive() async -> WidgetSnapshot? {
        guard var auth = SharedStore.loadAuth(), !auth.access.isEmpty else { return nil }
        if auth.isExpiringSoon {
            if let fresh = await refreshAuth(auth) { auth = fresh }
        }
        let base = normalize(auth.baseURL)

        // Per-endpoint resilience, mirroring HomeView.load(): one dead
        // endpoint must not blank the whole widget.
        async let v: Vitals? = get(base, "/api/control/vitals", auth.access)
        async let o: Overview? = get(base, "/api/control/overview", auth.access)
        async let z: ZaiUsage? = get(base, "/api/control/zai_usage", auth.access)
        async let a: Automations? = get(base, "/api/control/automations", auth.access)
        async let at: Attention? = get(base, "/api/control/attention", auth.access)
        async let w: Activity? = get(base, "/api/control/activity", auth.access)
        async let bh: BridgeHealth? = get(normalize(auth.bridgeURL), "/health", auth.access)
        let (v2, o2, z2, a2, at2, w2, bh2) = await (v, o, z, a, at, w, bh)

        // Every CC endpoint failed → offline; fall back to the cached copy.
        if v2 == nil && o2 == nil && z2 == nil && a2 == nil && at2 == nil && w2 == nil {
            return nil
        }
        return WidgetSnapshot(
            ts: Date().timeIntervalSince1970,
            gatewayOK: o2?.bridge?.reachable ?? true,
            cpu: Int(v2?.cpu_pct ?? 0),
            mem: memLabel(v2),
            disk: diskLabel(v2),
            upDays: (v2?.uptime_seconds ?? 0) / 86400,
            llm: (z2?.windows ?? []).prefix(3).map {
                .init(label: $0.label, used: $0.used ?? 0, limit: $0.limit ?? 0, pct: $0.percent ?? 0)
            },
            cronsActive: a2?.active ?? 0,
            cronsFailing: a2?.failing ?? 0,
            attentionCount: at2?.count ?? 0,
            attentionCritical: at2?.critical ?? 0,
            alerts: (at2?.alerts ?? []).prefix(3).map {
                .init(sev: $0.severity, title: $0.title, msg: $0.msg ?? "")
            },
            sessions: (w2?.sessions ?? []).prefix(3).map {
                .init(title: $0.title ?? "Untitled", source: $0.source ?? "",
                      ago: ago($0.ago_seconds ?? 0), live: $0.active ?? false)
            },
            deviceRegistered: bh2?.device_registered ?? false,
            apnsConfigured: bh2?.apns_configured ?? false
        )
    }

    static func memLabel(_ v: Vitals?) -> String {
        guard let used = v?.mem_used_mb, let total = v?.mem_total_mb else { return "—" }
        return "\(used / 1024)/\(total / 1024)G"
    }

    static func diskLabel(_ v: Vitals?) -> String {
        guard let used = v?.disk_used_gb, let total = v?.disk_total_gb else { return "—" }
        return "\(used)/\(total)G"
    }

    /// Exchange the refresh token for fresh bearer tokens; persists the new
    /// pair so the next reload starts warm. Returns nil on failure.
    static func refreshAuth(_ auth: WidgetAuth) async -> WidgetAuth? {
        guard !auth.refresh.isEmpty,
              let url = URL(string: normalize(auth.baseURL) + "/auth/native/refresh") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable { var refresh_token: String; var provider: String }
        req.httpBody = try? JSONEncoder().encode(Body(refresh_token: auth.refresh, provider: "basic"))
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Tokens: Decodable {
            var access_token: String
            var refresh_token: String
            var expires_at: TimeInterval
        }
        guard let t = try? JSONDecoder().decode(Tokens.self, from: data) else { return nil }
        let fresh = WidgetAuth(baseURL: auth.baseURL, bridgeURL: auth.bridgeURL,
                               access: t.access_token, refresh: t.refresh_token,
                               expiresAt: t.expires_at)
        SharedStore.saveAuth(fresh)
        return fresh
    }

    private static func get<T: Decodable>(_ base: String, _ path: String, _ token: String) async -> T? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
