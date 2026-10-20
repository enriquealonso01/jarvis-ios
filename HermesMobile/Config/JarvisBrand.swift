import SwiftUI

/// JARVIS "Orbital Core v2" brand layer: the approved palette and the Orbital mark
/// (brand kit `JARVIS_Orbital_Core_Brand_Kit_v2`, `brand-tokens.json` and
/// `docs/IMPLEMENTATION_SPEC.md`). Ported from JARVIS v2's DesignSystem package. Hermex's own
/// layout and interaction model stay; this only supplies the colors and the mark.
enum JarvisBrand {
    /// #070E14, the dark foundation.
    static let obsidianHex: UInt32 = 0x070E14
    /// #E6FFFF, the brightest core and primary foreground on dark.
    static let iceCoreHex: UInt32 = 0xE6FFFF
    /// #3FD6F5, focus, activity and selection.
    static let jarvisCyanHex: UInt32 = 0x3FD6F5
    /// #0E7490, supporting accent and darker borders.
    static let deepTealHex: UInt32 = 0x0E7490
    /// #A7B3BD, secondary labels and dividers.
    static let metallicGrayHex: UInt32 = 0xA7B3BD
    /// #0C1B24, cards and secondary backgrounds.
    static let deepSurfaceHex: UInt32 = 0x0C1B24
    /// #213C4B, the dark UI hairline.
    static let surfaceBorderHex: UInt32 = 0x213C4B

    static let obsidian = Color(jarvisHex: obsidianHex)
    static let iceCore = Color(jarvisHex: iceCoreHex)
    static let jarvisCyan = Color(jarvisHex: jarvisCyanHex)
    static let deepTeal = Color(jarvisHex: deepTealHex)
    static let metallicGray = Color(jarvisHex: metallicGrayHex)
    static let deepSurface = Color(jarvisHex: deepSurfaceHex)
    static let surfaceBorder = Color(jarvisHex: surfaceBorderHex)
}

/// sRGB hex → Color without UIKit/AppKit (works on iOS + macOS).
extension Color {
    init(jarvisHex hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Orbital mark

/// Orbital Core agent-presentation states (kit IMPLEMENTATION_SPEC §Animation
/// semantics). Values are the kit's orbit periods in seconds; the core/pulse
/// periods ride along per state. States must be driven by REAL events —
/// never fabricated timers (spec "What NOT to do").
enum OrbitalState: String, Sendable, CaseIterable {
    /// Agent ready, not capturing sound.
    case idle
    /// Microphone recording actually active.
    case listening
    /// A request is processing / tools executing.
    case thinking
    /// Speaking or streaming a response.
    case responding

    /// Outer orbit period (s) — kit brand-tokens.json `animations`.
    var outerOrbitSeconds: Double {
        switch self {
        case .idle: 32
        case .listening: 13
        case .thinking: 7
        case .responding: 17
        }
    }

    /// Inner orbit period (s), counter-rotating.
    var innerOrbitSeconds: Double {
        switch self {
        case .idle: 46
        case .listening: 20
        case .thinking: 10
        case .responding: 21
        }
    }

    /// Core effect period (s): idle breath / listening ripple /
    /// thinking scan / responding pulse.
    var coreEffectSeconds: Double {
        switch self {
        case .idle: 5.5
        case .listening: 1.7
        case .thinking: 1.6
        case .responding: 1.35
        }
    }
}

/// SwiftUI equivalent of the kit's orbital mark: a luminous diamond core
/// inside thin concentric orbital tracks with tracking arcs. Renders from the
/// approved kit geometry (svg/jarvis-orbital-static.svg, 512×512 viewBox
/// normalized) so no raster/PNG asset is needed in the package. Motion is
/// derived from a TimelineView clock (deterministic, no autoreverse drift),
/// honors the OS Reduce Motion setting by rendering the static composition,
/// and stays restrained (thin lines, one cyan focus accent) per the spec.
struct OrbitalCoreView: View {
    let state: OrbitalState
    /// Static rendering (kit spec: prefer static on navigation headers /
    /// passive surfaces; animated only on active status surfaces).
    let isStatic: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: OrbitalState = .idle, isStatic: Bool = false) {
        self.state = state
        self.isStatic = isStatic
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion || isStatic)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                draw(in: &context, size: size, t: (reduceMotion || isStatic) ? 0 : t)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("JARVIS orbital mark")
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        switch state {
        case .idle: "Idle"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .responding: "Responding"
        }
    }

    // MARK: drawing (kit geometry normalized from the 512-unit viewBox)

    private func draw(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let s = min(size.width, size.height)
        guard s > 0 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let unit = s / 512.0 // kit viewBox units → points
        let cyan = JarvisBrand.jarvisCyan
        let ice = JarvisBrand.iceCore
        let teal = JarvisBrand.deepTeal
        let gray = JarvisBrand.metallicGray

        // Radial mist behind everything (r=218 in kit units).
        let mistRect = CGRect(x: c.x - 218 * unit, y: c.y - 218 * unit,
                              width: 436 * unit, height: 436 * unit)
        context.fill(Path(ellipseIn: mistRect), with: .radialGradient(
            Gradient(colors: [cyan.opacity(0.14), teal.opacity(0.05), .clear]),
            center: c, startRadius: 0, endRadius: 218 * unit))

        // Ambient core glow (restrained — spec: glow limited to the mark).
        let glowRect = CGRect(x: c.x - 116 * unit, y: c.y - 116 * unit,
                              width: 232 * unit, height: 232 * unit)
        context.fill(Path(ellipseIn: glowRect), with: .radialGradient(
            Gradient(colors: [cyan.opacity(0.16), .clear]),
            center: c, startRadius: 0, endRadius: 116 * unit))

        // OUTER orbit (kit r=194): faint full track + gradient arc + tracker.
        context.stroke(circlePath(center: c, radius: 194 * unit),
                       with: .color(cyan.opacity(0.30)), lineWidth: 1.4 * unit)
        let outerAngle = -84 + 360 * t / state.outerOrbitSeconds
        context.stroke(rotatedPath(circlePath(center: c, radius: 194 * unit)
            .trimmedPath(from: 0, to: 0.28), around: c, degrees: outerAngle),
            with: .linearGradient(orbitGradient,
                startPoint: CGPoint(x: c.x - 180 * unit, y: c.y - 180 * unit),
                endPoint: CGPoint(x: c.x + 185 * unit, y: c.y + 185 * unit)),
            style: StrokeStyle(lineWidth: 5 * unit, lineCap: .round))
        drawTracker(&context, center: c, radius: 194 * unit, angle: outerAngle,
                    unit: unit, color: ice, r: 7)

        // Hairline ring (kit r=180).
        context.stroke(circlePath(center: c, radius: 180 * unit),
                       with: .color(gray.opacity(0.20)), lineWidth: 1 * unit)

        // INNER orbit (kit r=160): track + counter-rotating arc + dotted ring.
        context.stroke(circlePath(center: c, radius: 160 * unit),
                       with: .color(gray.opacity(0.42)), lineWidth: 1.4 * unit)
        let innerAngle = 28 - 360 * t / state.innerOrbitSeconds
        context.stroke(rotatedPath(circlePath(center: c, radius: 160 * unit)
            .trimmedPath(from: 0, to: 0.22), around: c, degrees: innerAngle),
            with: .linearGradient(orbitGradient,
                startPoint: CGPoint(x: c.x - 150 * unit, y: c.y - 150 * unit),
                endPoint: CGPoint(x: c.x + 150 * unit, y: c.y + 150 * unit)),
            style: StrokeStyle(lineWidth: 3.5 * unit, lineCap: .round))
        context.stroke(circlePath(center: c, radius: 148 * unit),
                       with: .color(Color(jarvisHex: 0x9AEFFF).opacity(0.7)),
                       style: StrokeStyle(lineWidth: 3 * unit, lineCap: .round,
                                          dash: [1 * unit, 14 * unit]))
        context.stroke(circlePath(center: c, radius: 123 * unit),
                       with: .color(gray.opacity(0.26)), lineWidth: 1 * unit)

        // State effect layer.
        switch state {
        case .idle:
            break // calm orbits are the whole show
        case .listening:
            // Outward sensor ripples (two offset phases).
            for i in 0..<2 {
                let phase = ((t / state.coreEffectSeconds) + Double(i) / 2)
                    .truncatingRemainder(dividingBy: 1)
                let r = 150 * unit * (1 + 0.45 * phase)
                context.stroke(circlePath(center: c, radius: r),
                               with: .color(cyan.opacity(0.5 * (1 - phase))),
                               lineWidth: 2 * unit)
            }
        case .thinking:
            // Scanning light arc sweeping faster than the orbits.
            let scanAngle = 360 * t / state.coreEffectSeconds
            context.stroke(rotatedPath(circlePath(center: c, radius: 135 * unit)
                .trimmedPath(from: 0, to: 0.14), around: c, degrees: scanAngle),
                with: .color(ice.opacity(0.65)),
                style: StrokeStyle(lineWidth: 3 * unit, lineCap: .round))
        case .responding:
            // Measured pulse rings synced to the kit pulse period.
            let phase = (t / state.coreEffectSeconds)
                .truncatingRemainder(dividingBy: 1)
            let r = (180 + 30 * phase) * unit
            context.stroke(circlePath(center: c, radius: r),
                           with: .color(ice.opacity(0.35 * (1 - phase))),
                           lineWidth: 1.5 * unit)
        }

        // Diamond core (kit paths, glow ring + bevel body + inner facets).
        // responding adds a rhythmic scale pulse to the halo/body only.
        var coreScale: CGFloat = 1
        if state == .responding && !reduceMotion {
            let p = (t / state.coreEffectSeconds)
                .truncatingRemainder(dividingBy: 1)
            coreScale = 1 + 0.05 * sin(2 * .pi * p)
        } else if state == .idle && !reduceMotion {
            // Gentle breathing.
            let p = (t / state.coreEffectSeconds)
                .truncatingRemainder(dividingBy: 1)
            coreScale = 1 + 0.02 * sin(2 * .pi * p)
        }
        drawDiamond(&context, center: c, unit: unit * coreScale,
                    cyan: cyan, ice: ice, teal: teal)
    }

    private func drawTracker(_ context: inout GraphicsContext, center: CGPoint,
                             radius: CGFloat, angle: Double, unit: CGFloat,
                             color: Color, r: CGFloat) {
        let rad = (angle - 90) * .pi / 180 // kit tracker sits at the arc head
        let p = CGPoint(x: center.x + radius * unit * CGFloat(cos(rad)),
                        y: center.y + radius * unit * CGFloat(sin(rad)))
        let dot = CGRect(x: p.x - r * unit, y: p.y - r * unit,
                         width: 2 * r * unit, height: 2 * r * unit)
        context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.92)))
        let halo = dot.insetBy(dx: -5 * unit, dy: -5 * unit)
        context.fill(Path(ellipseIn: halo), with: .color(JarvisBrand.jarvisCyan.opacity(0.30)))
    }

    private func drawDiamond(_ context: inout GraphicsContext, center: CGPoint,
                             unit: CGFloat, cyan: Color, ice: Color, teal: Color) {
        // Kit: outer diamond M256 141 L371 256 L256 371 L141 256 (stroke 7),
        // glow ring at ±4, inner facet M256 167 L345 256 L256 345 L167 256.
        func diamond(_ inset: CGFloat) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: center.x, y: center.y - (115 - inset) * unit))
            p.addLine(to: CGPoint(x: center.x + (115 - inset) * unit, y: center.y))
            p.addLine(to: CGPoint(x: center.x, y: center.y + (115 - inset) * unit))
            p.addLine(to: CGPoint(x: center.x - (115 - inset) * unit, y: center.y))
            p.closeSubpath()
            return p
        }
        // Glow ring.
        context.stroke(diamond(4), with: .color(cyan.opacity(0.45)),
                       lineWidth: 10 * unit)
        // Bevel body: obsidian fill with a cyan→ice gradient stroke.
        context.fill(diamond(0), with: .color(JarvisBrand.obsidian.opacity(0.60)))
        context.stroke(diamond(0), with: .linearGradient(
            Gradient(colors: [ice, cyan, teal, ice]),
            startPoint: CGPoint(x: center.x - 90 * unit, y: center.y - 90 * unit),
            endPoint: CGPoint(x: center.x + 90 * unit, y: center.y + 90 * unit)),
            lineWidth: 7 * unit)
        // Inner facet hairline.
        context.stroke(diamond(24), with: .color(Color(jarvisHex: 0xD1FAFF).opacity(0.42)),
                       lineWidth: 1.4 * unit)
    }

    private var orbitGradient: Gradient {
        Gradient(colors: [
            JarvisBrand.deepTeal,
            JarvisBrand.jarvisCyan,
            JarvisBrand.iceCore,
            JarvisBrand.jarvisCyan,
        ])
    }

    private func circlePath(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                               width: 2 * radius, height: 2 * radius))
    }

    /// Rotates a path about `center` by `degrees` (GraphicsContext.stroke has
    /// no rotation parameter, so arcs are pre-rotated with a transform).
    private func rotatedPath(_ path: Path, around center: CGPoint,
                             degrees: Double) -> Path {
        let radians = CGFloat(degrees) * .pi / 180
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: radians)
            .translatedBy(x: -center.x, y: -center.y)
        return path.applying(transform)
    }
}
