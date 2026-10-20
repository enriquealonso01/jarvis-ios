import Foundation

/// The one Hermes host this app talks to. JARVIS v3 has no server list and no connect form:
/// the address is baked in and the only first-run step is signing in to it.
///
/// Debug builds can point at another host (a local `scripts/local-hermes` on the CI runner)
/// with the `JarvisServerAddress` launch argument or the `JARVIS_DEV_ADDRESS` environment
/// variable. Release builds always use the production address.
enum JarvisServer {
    static let productionAddress = URL(string: "https://jarvis.enriquecodes.com")!

    static var address: URL {
        #if DEBUG
        let override = UserDefaults.standard.string(forKey: "JarvisServerAddress")
            ?? ProcessInfo.processInfo.environment["JARVIS_DEV_ADDRESS"]
        if let override, let parsed = try? BotConnection.address(override) { return parsed }
        #endif
        return productionAddress
    }

    /// The host as people read it, for the sign-in screen and Settings.
    static var displayHost: String { address.host ?? address.absoluteString }
}
