#if DEBUG
import Foundation

/// Debug-only sign-in from launch environment variables, so an agent driving a simulator (or
/// the Maestro lane on CI against `scripts/local-hermes`) is never blocked on the sign-in
/// screen. It goes through the normal path, so the record lands in the simulator's Keychain
/// as a manual sign-in would.
///
/// - `JARVIS_DEV_USERNAME`, `JARVIS_DEV_PASSWORD`: the dashboard sign-in.
/// - `JARVIS_DEV_ADDRESS` (or the `JarvisServerAddress` launch argument): the host, read by
///   `JarvisServer.address`; the production host when absent.
@MainActor
enum DevAutoLogin {
    /// The sign-in under way, if any. It is owned here rather than by the calling view task,
    /// because the root view is rebuilt during launch and a cancelled view task would cancel
    /// the login requests with it.
    private static var inFlight: Task<Void, Never>?

    /// Called from the root view's `.task(id: authManager.state)`. Concurrent calls share one
    /// attempt. A failed sign-in leaves the state unchanged and is therefore not retried.
    static func run(
        authManager: AuthManager,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        if let inFlight { return await inFlight.value }
        let task = Task { await signIn(authManager: authManager, environment: environment) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private static func signIn(authManager: AuthManager, environment: [String: String]) async {
        guard case .unconfigured = authManager.state,
              let username = environment["JARVIS_DEV_USERNAME"],
              let password = environment["JARVIS_DEV_PASSWORD"] else { return }
        let address = JarvisServer.address
        let candidate = BotConnection(id: UUID(), name: "JARVIS", address: address,
                                      username: username, password: password)
        let http = HermesConnection(connection: candidate)
        do {
            try await http.signIn()
        } catch {
            NSLog("DevAutoLogin: sign-in failed: %@", String(describing: error))
            return
        }
        var record = http.connection
        record.hermesVersion = http.serverVersion
        record.installID = http.serverInstallID
        if !authManager.addHermesServer(record) {
            NSLog("DevAutoLogin: adding the server failed: %@", authManager.lastErrorMessage ?? "")
        }
    }
}
#endif
