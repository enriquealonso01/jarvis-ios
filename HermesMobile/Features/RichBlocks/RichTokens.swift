import SwiftUI
import UIKit

/// The design tokens the rich-block renderers (ported from JARVIS v2's DesignSystem package) read,
/// mapped onto the Orbital Core palette. v2 was dark-only; Hermex follows the system appearance,
/// so every colour here resolves for light and dark.
enum Tokens {
    enum Palette {
        private static func dynamic(light: UIColor, dark: UIColor) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
        private static let cyan = UIColor(JarvisBrand.jarvisCyan)
        private static let teal = UIColor(JarvisBrand.deepTeal)

        static let accent = dynamic(light: teal, dark: cyan)
        static let accentBorder = dynamic(light: teal.withAlphaComponent(0.45), dark: cyan.withAlphaComponent(0.55))
        static let accentLabel = dynamic(light: teal, dark: cyan)
        static let accentSurface = dynamic(light: teal.withAlphaComponent(0.10), dark: cyan.withAlphaComponent(0.14))
        static let onAccent = dynamic(light: .white, dark: UIColor(JarvisBrand.obsidian))

        static let textPrimary = Color(.label)
        static let textBody = Color(.label)
        static let textSecondary = Color(.secondaryLabel)
        static let textMuted = Color(.tertiaryLabel)

        static let border = Color(.separator)
        static let borderStrong = Color(.opaqueSeparator)
        static let elevated = Color(.secondarySystemBackground)
        static let raised = Color(.tertiarySystemBackground)
        static let sunken = Color(.systemGroupedBackground)
        static let cardBottom = Color(.secondarySystemBackground)
        static let selected = accentSurface
        static let option = Color(.tertiarySystemFill)
        static let optionSelected = accentSurface
        static let resultTrack = Color(.quaternarySystemFill)

        static let chartBar = dynamic(light: teal.withAlphaComponent(0.75), dark: cyan.withAlphaComponent(0.7))
        static let chartBarSelected = dynamic(light: teal, dark: cyan)
        static let chartGrid = Color(.separator)
        static let chartAxis = Color(.tertiaryLabel)
        static let chartValue = Color(.secondaryLabel)

        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
    }

    enum Radius {
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let segment: CGFloat = 8
    }

    enum Layout {
        static let hitTarget: CGFloat = 44
    }

    enum Spacing {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    enum Typography {
        static let body = Font.body
        static let cardTitle = Font.headline
        static let cardBody = Font.subheadline
    }
}

/// Markdown inside a rich block (a `markdown` block, a card's body), drawn with Hermex's own
/// markdown renderer so it reads like the rest of the chat.
struct MarkdownText: View {
    let source: String
    var font: Font = Tokens.Typography.body
    var color: Color = Tokens.Palette.textBody

    init(_ source: String, font: Font = Tokens.Typography.body, color: Color = Tokens.Palette.textBody) {
        self.source = source
        self.font = font
        self.color = color
    }

    var body: some View {
        MarkdownRenderer(content: source)
            .font(font)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
