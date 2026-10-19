import Foundation
import SwiftUI

/// Server connection settings (Settings tab / first-run Setup).
/// The server URL points at the public dashboard (jarvis.enriquecodes.com).
/// Codable wire struct persisted in UserDefaults by the ServerConfig store.
struct ServerConfigValues: Codable {
    var baseURL: String = "https://jarvis.enriquecodes.com"
    var bridgeBaseURL: String = "https://jarvis.enriquecodes.com/bridge"  // push bridge (:9160 via Caddy /bridge route)
    var voiceGWURL: String = "https://jarvis.enriquecodes.com"           // voice gateway (offer path: /voice-gw/api/offer)
}

@MainActor
final class ServerConfig: ObservableObject {
    static let shared = ServerConfig()

    private static let key = "jarvis.server.config.v1"

    @Published var config: ServerConfigValues {
        didSet { Self.persist(config) }
    }

    init() {
        #if DEBUG
        // Screenshot lane (inert without -SCREENSHOT_SEED): seed demo content
        // synchronously on a non-main queue BEFORE the first frame reads
        // AuthStore/ServerConfig. MainActor state writes (ServerConfig) hop
        // to main via the boot gate in JarvisApp.swift — AuthStore/Keychain
        // are nonisolated statics and safe off-main here.
        if ScreenshotSeed.isActive {
            ScreenshotSeed.seedKeychain()
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(ServerConfigValues.self, from: data) {
            config = decoded
        } else {
            config = ServerConfigValues()
        }
    }

    var configured: Bool {
        !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func persist(_ c: ServerConfigValues) {
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
