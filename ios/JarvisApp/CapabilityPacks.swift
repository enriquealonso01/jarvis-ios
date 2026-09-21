import Foundation
import SwiftUI

/// Capability packs: permissioned feature modules that can be added later
/// (health, photos, installed apps, location) WITHOUT redesigning the app.
///
/// A pack declares itself, asks for permissions, and contributes rows to the
/// More tab. JARVIS core ships with ZERO packs enabled — adding a feature is
/// "register a new struct", not "touch every screen".
protocol CapabilityPack: Identifiable {
    var id: String { get }              // e.g. "health"
    var displayName: String { get }     // human name for settings/more list
    var symbol: String { get }          // SF Symbol
    var isEnabled: Bool { get }         // did the user enable it?
    var permissionSummary: String { get }
    /// Rows shown in the More tab when enabled.
    @MainActor var destinations: [CapabilityDestination] { get }
}

/// A screen a pack contributes.
struct CapabilityDestination: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let destination: AnyView
}

/// Central registry. New packs self-register here at init time.
@MainActor
final class CapabilityRegistry: ObservableObject {
    static let shared = CapabilityRegistry()

    @Published private(set) var packs: [CapabilityPack] = []

    func register(_ pack: CapabilityPack) {
        guard !packs.contains(where: { $0.id == pack.id }) else { return }
        packs.append(pack)
    }

    var enabledPacks: [CapabilityPack] { packs.filter { $0.isEnabled } }
}

/// Placeholder pack demonstrating the extension point. Disabled by default;
/// proves that a pack can be registered and listed without touching any
/// other screen. Real packs (health/photos/location) follow this template.
struct ExampleCapabilityPack: CapabilityPack {
    let id = "example"
    let displayName = "Example Pack"
    let symbol = "puzzlepiece.extension"
    let isEnabled = false
    let permissionSummary = "No permissions requested (template)"
    var destinations: [CapabilityDestination] { [] }
}
