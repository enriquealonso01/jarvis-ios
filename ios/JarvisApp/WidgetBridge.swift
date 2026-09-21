import Foundation
import WidgetKit

/// App → widget bridge. Publishes a compact Control-Center snapshot plus the
/// auth material into the shared app-group container so the JarvisWidgets
/// extension can render live data without holding credentials of its own.
/// Storage is the shared keychain access group (NOT an app group — the
/// APP_GROUPS portal attach is web-UI-only; verified 2026-09-21).
/// JSON shapes MUST mirror ios/Widgets/WidgetCore.swift — the widget decodes
/// exactly these keys. Change both files together.
enum WidgetBridge {
    // Shared keychain access group, mirrored in JarvisApp.entitlements and
    // Widgets/JarvisWidgets.entitlements. Single declared group on both
    // targets = default access group; SecItem needs no explicit attr.
    static let accessGroup = "com.enriquecodes.jarvis.widgetshared"
    private static let snapshotKey = "jarvis.widget.snapshot.v1"
    private static let authKey = "jarvis.widget.auth.v1"

    // Codable shapes mirroring WidgetCore.swift (explicit snake_case keys).
    struct Snapshot: Codable {
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

    struct Auth: Codable {
        var baseURL: String
        var bridgeURL: String
        var access: String
        var refresh: String
        var expiresAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case baseURL, bridgeURL, access, refresh
            case expiresAt = "expires_at"
        }
    }

    /// Mirror the stored session tokens into the group container. Called on
    /// every login / token refresh / manual-token apply so widgets always
    /// hold a live bearer + refresh pair.
    @MainActor
    static func publishAuth() {
        let cfg = ServerConfig.shared.config
        let auth = Auth(
            baseURL: cfg.baseURL,
            bridgeURL: cfg.bridgeBaseURL,
            access: AuthStore.shared.accessToken ?? "",
            refresh: AuthStore.shared.refreshToken ?? "",
            expiresAt: AuthStore.shared.expiresAt
        )
        if let data = try? JSONEncoder().encode(auth) {{
            kcSet(data, key: authKey)
        }}
    }

    /// Build a snapshot from the freshly loaded Home data, persist it, and
    /// kick WidgetKit to reload every widget timeline.
    @MainActor
    static func sync(vitals: Vitals?, bridge: Overview.Bridge?, zai: ZaiUsage?,
                     autos: Automations?, attention: Attention?, health: BridgeHealth?,
                     activity: Activity?) {
        let snap = Snapshot(
            ts: Date().timeIntervalSince1970,
            gatewayOK: bridge?.reachable ?? true,
            cpu: Int(vitals?.cpu_pct ?? 0),
            mem: memLabel(vitals),
            disk: diskLabel(vitals),
            upDays: (vitals?.uptime_seconds ?? 0) / 86400,
            llm: (zai?.windows ?? []).prefix(3).map {
                .init(label: $0.label, used: $0.used ?? 0, limit: $0.limit ?? 0, pct: $0.percent ?? 0)
            },
            cronsActive: autos?.active ?? 0,
            cronsFailing: autos?.failing ?? 0,
            attentionCount: attention?.count ?? 0,
            attentionCritical: attention?.critical ?? 0,
            alerts: (attention?.alerts ?? []).prefix(3).map {
                .init(sev: $0.severity, title: $0.title, msg: $0.msg ?? "")
            },
            sessions: (activity?.sessions ?? []).prefix(3).map {
                .init(title: $0.title ?? "Untitled", source: $0.source ?? "",
                      ago: HomeView.ago($0.ago_seconds ?? 0), live: $0.active ?? false)
            },
            deviceRegistered: health?.device_registered ?? false,
            apnsConfigured: health?.apns_configured ?? false
        )
        if let data = try? JSONEncoder().encode(snap) {{
            kcSet(data, key: snapshotKey)
        }}
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func kcSet(_ data: Data, key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func memLabel(_ v: Vitals?) -> String {
        guard let used = v?.mem_used_mb, let total = v?.mem_total_mb else { return "—" }
        return "\(used / 1024)/\(total / 1024)G"
    }

    private static func diskLabel(_ v: Vitals?) -> String {
        guard let used = v?.disk_used_gb, let total = v?.disk_total_gb else { return "—" }
        return "\(used)/\(total)G"
    }
}
