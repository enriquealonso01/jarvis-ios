import UIKit

/// Backlog #9: centralized haptics so every view fires the same patterns.
/// All call sites run on the main actor (SwiftUI actions), and
/// UIFeedbackGenerator is documented as main-thread-only — so the whole
/// enum is MainActor-isolated rather than hopping per call.
///
/// Settings toggle (build 69): every entry checks Haptics.isEnabled first —
/// one UserDefaults read beats a stray vibration after the user turned them
/// off. Key is exported so the Settings toggle's @AppStorage uses the SAME
/// key (a mismatched key would render the toggle a lie).
@MainActor
enum Haptics {
    static let enabledKey = "jarvis.settings.haptics"

    static var isEnabled: Bool {
        // Absent key defaults to ON (existing behavior preserved).
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func success() { guard isEnabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { guard isEnabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func warning() { guard isEnabled else { return }; UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { guard isEnabled else { return }; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func heavy() { guard isEnabled else { return }; UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
}
