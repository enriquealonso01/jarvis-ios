import Foundation
import Persistence

/// v2 feature flags (Item 1). Everything behind a flag until the feature that
/// consumes it lands; flags flip on permanently once M1 ships the surface.
enum V2Flags {
    /// GRDB local store open at launch (feature #4). v1 flows are untouched —
    /// they keep their server-backed paths; this only warms the store.
    static let localStore = true
}

/// Launch-time holder for the shared PersistenceStore. Not a singleton by
/// taste — the store must be exactly one instance per process (SQLite file
/// locking), and SwiftUI `App.init` is the earliest safe open point.
@MainActor
final class LocalStoreBootstrap: ObservableObject {
    static let shared = LocalStoreBootstrap()

    /// The process-wide store, or nil if opening failed (offline-first is a
    /// degradation, never a crash — v1 behavior continues untouched).
    private(set) var store: PersistenceStore?

    private init() {}

    /// Idempotent: opens the store once; repeated calls are no-ops.
    func warmUp() {
        guard store == nil else { return }
        do {
            // App Group container when the entitlement exists (feature #40
            // prep: the widgets extension will read the same file); fall back
            // to the app's own support directory otherwise.
            let dir: URL
            if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.enriquecodes.jarvis") {
                dir = group
            } else {
                dir = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true
                )
            }
            let path = dir.appendingPathComponent("jarvis-v2.sqlite").path
            store = try PersistenceStore(path: path)
            #if DEBUG
            print("[v2] PersistenceStore opened at \(path)")
            #endif
        } catch {
            // Never block launch on storage failure (v1 CI/flows must stay green).
            print("[v2] PersistenceStore failed to open: \(error)")
            store = nil
        }
    }
}
