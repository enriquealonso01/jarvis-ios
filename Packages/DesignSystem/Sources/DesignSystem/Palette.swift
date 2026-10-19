import SwiftUI

// MARK: - Orbital Core semantic UI tokens (UI expansion package, 02_DESIGN_SYSTEM)
//
// The package's draft palette (canvas / elevated / hover / border / text /
// accent / danger / success / warning) mapped onto the APPROVED Orbital Core
// v2 brand tokens (`Tokens.Brand`). Components use these semantic names —
// never raw hex — so a palette change is one edit here. Dark only: the v2
// shell forces the dark scheme (the spec's "dark primary"; no light variant
// was designed).

extension Tokens {

    public enum Palette {
        // MARK: Surfaces

        /// Overall canvas (Obsidian #070E14). Chat, header, composer well.
        public static let canvas = Brand.obsidian
        /// Navigation, composer container, drawers (Deep Surface #0C1B24).
        public static let elevated = Brand.deepSurface
        /// Rich card gradient, top-leading stop.
        public static let cardTop = Color(hex: 0x0F202B)
        /// Rich card gradient, bottom-trailing stop.
        public static let cardBottom = Color(hex: 0x0B1821)
        /// User bubble / pressed rows (one step above elevated).
        public static let raised = Color(hex: 0x15293A)
        /// Active sidebar row / selected segment.
        public static let selected = Color(hex: 0x173341)
        /// Recessed tracks: segmented-control well, form inputs, search well.
        public static let sunken = Color(hex: 0x08131B)
        /// Choice rows inside cards (poll / quiz options).
        public static let option = Color(hex: 0x0F1E29)
        /// Selected choice row.
        public static let optionSelected = Color(hex: 0x123542)

        // MARK: Lines

        /// Dark UI hairline (Surface Border #213C4B).
        public static let border = Brand.surfaceBorder
        /// Stronger boundary: selected option, focused input.
        public static let borderStrong = Color(hex: 0x3B8FA8)
        /// Near-invisible divider under the header.
        public static let hairline = Color.white.opacity(0.05)

        // MARK: Text

        /// Primary foreground (Ice Core #E6FFFF).
        public static let textPrimary = Brand.iceCore
        /// Long-form assistant text (a touch softer than primary).
        public static let textBody = Color(hex: 0xD4E4EB)
        /// Supporting labels (Metallic Gray #A7B3BD).
        public static let textSecondary = Brand.metallicGray
        /// Metadata, placeholders, section labels (≥4.5:1 on canvas).
        public static let textMuted = Color(hex: 0x7A8D9B)
        /// Sidebar section label (PROJECTS / RECENTS).
        public static let sectionLabel = Color(hex: 0x8199AC)

        // MARK: Accent

        /// Focus / activity / primary action (JARVIS Cyan #3FD6F5).
        public static let accent = Brand.jarvisCyan
        /// Foreground on a cyan fill (send arrow, primary button label).
        public static let onAccent = Color(hex: 0x04202A)
        /// Tonal accent wash (chips, soft highlights).
        public static let accentSoft = Brand.jarvisCyan.opacity(0.14)
        /// Primary sidebar action fill ("New chat").
        public static let accentSurface = Color(hex: 0x0F2F3B)
        /// Primary sidebar action border.
        public static let accentBorder = Color(hex: 0x24505F)
        /// Label on the primary sidebar action.
        public static let accentLabel = Color(hex: 0xC9FAFF)

        // MARK: Status

        public static let danger = Color(hex: 0xF07878)
        public static let dangerFill = Color(hex: 0x803139)
        public static let dangerBorder = Color(hex: 0xAE5059)
        public static let success = Color(hex: 0x6ED5AD)
        public static let warning = Color(hex: 0xF3C46E)

        // MARK: Overlays

        /// Drawer / sheet scrim over the chat.
        public static let scrim = Color.black.opacity(0.6)

        // MARK: Data viz

        public static let chartBar = Color(hex: 0x50BFD9)
        public static let chartBarSelected = Color(hex: 0xD5F8FF)
        public static let chartAxis = Color(hex: 0x527082)
        public static let chartGrid = Color(hex: 0x263644)
        public static let chartValue = Color(hex: 0xC8E8F2)
        public static let resultTrack = Color(hex: 0x1F3341)
    }

    /// Corner radii (02_DESIGN_SYSTEM: 18–24 composer/card, 10–14 controls).
    public enum Radius {
        public static let composer: CGFloat = 24
        public static let card: CGFloat = 18
        public static let bubble: CGFloat = 19
        /// The user bubble's tail corner (bottom-trailing).
        public static let bubbleTail: CGFloat = 5
        public static let control: CGFloat = 12
        public static let row: CGFloat = 11
        public static let segment: CGFloat = 8
    }

    /// Shell layout metrics.
    public enum Layout {
        /// Minimum interactive target (Apple HIG + 02_DESIGN_SYSTEM).
        public static let hitTarget: CGFloat = 44
        /// Mobile chat horizontal gutter.
        public static let gutter: CGFloat = 16
        /// Composer horizontal inset from the screen edge.
        public static let composerInset: CGFloat = 12
        /// Custom chat header height (excluding the status bar).
        public static let headerHeight: CGFloat = 56
        /// Drawer: ~85% of the viewport, capped at 320pt (02_DESIGN_SYSTEM).
        public static let sidebarMaxWidth: CGFloat = 320
        /// Send button visual diameter (hit area stays 44pt).
        public static let sendDiameter: CGFloat = 34
        /// Vertical gap between transcript messages.
        public static let messageSpacing: CGFloat = 22
        /// Readable transcript cap on wide layouts.
        public static let transcriptMaxWidth: CGFloat = 780
    }

    /// Type ramp (system UI font; every size is a Dynamic Type style so it
    /// scales with the user's accessibility preference).
    public enum Typography {
        /// Header title.
        public static var headerTitle: Font { Font.callout.weight(.semibold) }
        /// Header subtitle.
        public static var headerSubtitle: Font { Font.caption2 }
        /// Message text (user bubble + assistant).
        public static var body: Font { Font.callout }
        /// Card titles (rich blocks).
        public static var cardTitle: Font { Font.footnote.weight(.bold) }
        /// Card supporting text.
        public static var cardBody: Font { Font.footnote }
        /// Metadata / fine print.
        public static var caption: Font { Font.caption }
        /// Sidebar section label (tracked uppercase).
        public static var sectionLabel: Font { Font.caption2.weight(.heavy) }
        /// Sidebar row.
        public static var row: Font { Font.subheadline }
        /// Primary button label.
        public static var button: Font { Font.footnote.weight(.bold) }
    }
}

// MARK: - Shared surfaces

/// The rich-card container (prototype `.rich-card`): deep-surface gradient,
/// surface-border hairline, 18pt continuous corners.
public struct JarvisCardBackground: ViewModifier {
    public var padding: CGFloat

    public init(padding: CGFloat = 14) {
        self.padding = padding
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, padding)
            .padding(.vertical, padding + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Tokens.Palette.cardTop, Tokens.Palette.cardBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .strokeBorder(Tokens.Palette.border, lineWidth: 1))
    }
}

extension View {
    /// Wraps content in the Orbital Core rich-card surface.
    public func jarvisCard(padding: CGFloat = 14) -> some View {
        modifier(JarvisCardBackground(padding: padding))
    }
}

/// Primary (cyan) and ghost button styles used by cards and sheets.
public struct JarvisButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, ghost, danger }
    public var kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind = .primary) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tokens.Typography.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, 17)
            .frame(minHeight: Tokens.Layout.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .fill(background))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Tokens.Palette.onAccent
        case .ghost: return Tokens.Palette.textPrimary
        case .danger: return Tokens.Palette.textPrimary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Tokens.Palette.accent
        case .ghost: return Tokens.Palette.raised
        case .danger: return Tokens.Palette.dangerFill
        }
    }
}

/// Icon-only header / toolbar button: 44pt hit area, 20pt glyph, secondary
/// tint, tonal press state.
public struct JarvisIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .regular))
            .foregroundStyle(Tokens.Palette.textSecondary)
            .frame(width: Tokens.Layout.hitTarget, height: Tokens.Layout.hitTarget)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                    .fill(configuration.isPressed ? Tokens.Palette.raised : Color.clear))
            .contentShape(Rectangle())
    }
}
