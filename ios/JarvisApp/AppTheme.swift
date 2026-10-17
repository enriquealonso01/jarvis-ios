import SwiftUI

/// Appearance settings (Settings tab): dark is the default and still the
/// "System" choice — the deployment's whole visual identity is dark, and a
/// light-mode JARVIS was never designed. Theme is a UserDefaults preference
/// (a cosmetic knob, NOT a security one — that's what Keychain is reserved
/// for; see AppLockStore for the contrast).
enum AppTheme: String, CaseIterable, Identifiable {
    case dark = "dark"
    case light = "light"
    case system = "system"

    var id: String { rawValue }

    static let defaultsKey = "jarvis.theme"

    /// Current selection (defaults to dark — matches UIUserInterfaceStyle:
    /// Dark in the Info.plist and the app's identity).
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .dark
    }

    static func set(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: defaultsKey)
    }

    /// The colorScheme the app WindowGroup forces. nil = follow the system.
    static var preferredColorScheme: ColorScheme? {
        switch current {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
