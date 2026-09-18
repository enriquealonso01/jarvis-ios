import UIKit

/// Backlog #9: centralized haptics so every view fires the same patterns.
/// All call sites run on the main actor (SwiftUI actions), and
/// UIFeedbackGenerator is documented as main-thread-only — so the whole
/// enum is MainActor-isolated rather than hopping per call.
@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
}
