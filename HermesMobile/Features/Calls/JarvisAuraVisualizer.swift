import SwiftUI
import MetalKit

// The Aura audio visualizer: a native port of LiveKit Agents UI's `AgentAudioVisualizerAura`
// (livekit/components-js, Apache License 2.0, https://github.com/livekit/components-js).
// The fragment shader is a line-by-line translation of the original GLSL into Metal Shading
// Language, and `JarvisAuraAnimator` is a port of `useAgentAudioVisualizerAura`.
// See THIRD_PARTY_NOTICES.md and Settings > About JARVIS for the attribution.

// MARK: - Props

/// LiveKit's `AgentState`.
enum AgentAudioVisualizerAuraState: String, CaseIterable {
    case disconnected, connecting, initializing, listening, thinking, speaking, idle, failed
    case preConnectBuffering = "pre-connect-buffering"
}

/// `themeMode`: dark uses bloom on a dark background, light inverts for a light one.
enum AgentAudioVisualizerAuraThemeMode: Float {
    case dark = 0
    case light = 1
}

/// `shape`: 1 = circle, 2 = line.
enum AgentAudioVisualizerAuraShape: Float {
    case circle = 1
    case line = 2
}

/// The React component's size variants (its `h-[..px]`), plus a custom edge for layouts.
enum AgentAudioVisualizerAuraSize: Equatable {
    case icon, sm, md, lg, xl
    case custom(CGFloat)

    var points: CGFloat {
        switch self {
        case .icon: return 24
        case .sm: return 56
        case .md: return 112
        case .lg: return 224
        case .xl: return 448
        case .custom(let value): return value
        }
    }
}

/// The values the shader runs on: the hook's `speed, scale, amplitude, frequency, brightness`.
struct JarvisAuraValues: Equatable {
    var speed: Float
    var scale: Float
    var amplitude: Float
    var frequency: Float
    var brightness: Float
}

// MARK: - Motion (useAgentAudioVisualizerAura)

/// The easing curves of the `motion` library the hook animates with.
enum JarvisAuraEasing {
    /// `ease: 'easeOut'` is cubic-bezier(0, 0, 0.58, 1).
    static func easeOut(_ progress: Double) -> Double {
        let x = min(1, max(0, progress))
        if x == 0 || x == 1 { return x }
        // Solve bezier x(s) = progress for s, then read y(s).
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let s = (low + high) / 2
            let bx = 3 * (1 - s) * s * s * 0.58 + s * s * s
            if bx < x { low = s } else { high = s }
        }
        let s = (low + high) / 2
        return 3 * (1 - s) * s * s + s * s * s
    }

    /// `type: 'spring', duration, bounce`: an under-damped spring that settles over `duration`.
    static func spring(_ elapsed: Double, duration: Double, bounce: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        guard elapsed < duration else { return 1 }
        let omega = 2 * Double.pi / duration
        let zeta = 1 - bounce
        let damped = omega * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * elapsed)
        return 1 - decay * (cos(damped * elapsed) + (zeta * omega / damped) * sin(damped * elapsed))
    }
}

/// One animated value: `animate(motionValue, target, transition)`.
struct JarvisAuraTrack: Equatable {
    enum Motion: Equatable {
        case hold
        /// `{ duration: 0.5, ease: 'easeOut' }`
        case ease(duration: Double)
        /// `{ type: 'spring', duration: 1.0, bounce: 0.35 }`
        case spring(duration: Double, bounce: Double)
        /// `[from, to]` with `{ duration: 0.35, ease: 'easeOut', repeat: Infinity, repeatType: 'mirror' }`
        case pulse(leg: Double)
    }

    var from: Float
    var to: Float
    var start: Double
    var motion: Motion

    static func hold(_ value: Float) -> JarvisAuraTrack {
        JarvisAuraTrack(from: value, to: value, start: 0, motion: .hold)
    }

    func value(at now: Double) -> Float {
        let elapsed = now - start
        switch motion {
        case .hold:
            return to
        case .ease(let duration):
            let p = JarvisAuraEasing.easeOut(elapsed / duration)
            return from + (to - from) * Float(p)
        case .spring(let duration, let bounce):
            let p = JarvisAuraEasing.spring(elapsed, duration: duration, bounce: bounce)
            return from + (to - from) * Float(p)
        case .pulse(let leg):
            let legs = max(0, elapsed) / leg
            let index = Int(legs.rounded(.down))
            let p = JarvisAuraEasing.easeOut(legs - Double(index))
            let forward = index % 2 == 0
            let a = forward ? from : to
            let b = forward ? to : from
            return a + (b - a) * Float(p)
        }
    }

    /// `motionValue.isAnimating()`: true until a finite transition has run its course.
    func isAnimating(at now: Double) -> Bool {
        switch motion {
        case .hold: return false
        case .ease(let duration): return now - start < duration
        case .spring(let duration, _): return now - start < duration
        case .pulse: return true
        }
    }
}

/// The hook's state machine: what each agent state animates the Aura to.
struct JarvisAuraAnimator {
    // DEFAULT_SPEED, DEFAULT_AMPLITUDE, DEFAULT_FREQUENCY, DEFAULT_SCALE, DEFAULT_BRIGHTNESS.
    private(set) var speed: Float = 10
    private(set) var scale = JarvisAuraTrack.hold(0.2)
    private(set) var amplitude = JarvisAuraTrack.hold(2)
    private(set) var frequency = JarvisAuraTrack.hold(0.5)
    private(set) var brightness = JarvisAuraTrack.hold(1.5)
    private(set) var state: AgentAudioVisualizerAuraState?

    private static let transition = JarvisAuraTrack.Motion.ease(duration: 0.5)

    /// The settled values for a state, once its transition has run (pulsing states mid-pulse).
    static func values(for state: AgentAudioVisualizerAuraState, at time: Double = 100) -> JarvisAuraValues {
        var animator = JarvisAuraAnimator()
        animator.apply(state: state, now: 0)
        return animator.values(now: time, volume: 0)
    }

    private func track(from track: JarvisAuraTrack, to target: Float, now: Double,
                       motion: JarvisAuraTrack.Motion) -> JarvisAuraTrack {
        JarvisAuraTrack(from: track.value(at: now), to: target, start: now, motion: motion)
    }

    /// The hook's first effect: runs when `state` changes.
    mutating func apply(state newState: AgentAudioVisualizerAuraState, now: Double) {
        guard state != newState else { return }
        state = newState
        let ease = Self.transition
        switch newState {
        case .idle, .failed, .disconnected:
            speed = 10
            scale = track(from: scale, to: 0.2, now: now, motion: ease)
            amplitude = track(from: amplitude, to: 1.2, now: now, motion: ease)
            frequency = track(from: frequency, to: 0.4, now: now, motion: ease)
            brightness = track(from: brightness, to: 1.0, now: now, motion: ease)
        case .listening, .preConnectBuffering:
            speed = 20
            scale = track(from: scale, to: 0.3, now: now, motion: .spring(duration: 1.0, bounce: 0.35))
            amplitude = track(from: amplitude, to: 1.0, now: now, motion: ease)
            frequency = track(from: frequency, to: 0.7, now: now, motion: ease)
            brightness = JarvisAuraTrack(from: 1.5, to: 2.0, start: now, motion: .pulse(leg: 0.35))
        case .thinking, .connecting, .initializing:
            speed = 30
            scale = track(from: scale, to: 0.3, now: now, motion: ease)
            amplitude = track(from: amplitude, to: 0.5, now: now, motion: ease)
            frequency = track(from: frequency, to: 1.0, now: now, motion: ease)
            brightness = JarvisAuraTrack(from: 0.5, to: 2.5, start: now, motion: .pulse(leg: 0.35))
        case .speaking:
            speed = 70
            scale = track(from: scale, to: 0.3, now: now, motion: ease)
            amplitude = track(from: amplitude, to: 0.75, now: now, motion: ease)
            frequency = track(from: frequency, to: 1.25, now: now, motion: ease)
            brightness = track(from: brightness, to: 1.5, now: now, motion: ease)
        }
    }

    /// The hook's second effect: while speaking, the voice level sets the scale at once, but
    /// only once the state's own scale transition has finished.
    mutating func values(now: Double, volume: Double) -> JarvisAuraValues {
        if state == .speaking, volume > 0, !scale.isAnimating(at: now) {
            scale = .hold(0.2 + 0.2 * Float(min(1, max(0, volume))))
        }
        return JarvisAuraValues(speed: speed, scale: scale.value(at: now), amplitude: amplitude.value(at: now),
                                frequency: frequency.value(at: now), brightness: brightness.value(at: now))
    }
}

/// What a call phase means to the Aura (the voice screen's states are LiveKit's agent states).
extension JarvisVoicePhase {
    var auraState: AgentAudioVisualizerAuraState {
        switch self {
        case .ready: return .idle
        case .failed: return .failed
        case .connecting: return .connecting
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        }
    }
}

// MARK: - SwiftUI view

/// The reusable Aura view, with the React component's prop names. LiveKit's default colour is
/// #1FD5F9; JARVIS draws it in Jarvis Cyan #3FD6F5. Under Reduce Motion (or `isStatic`) it draws
/// one still, dimmed frame.
struct AgentAudioVisualizerAura: View {
    var size: AgentAudioVisualizerAuraSize = .lg
    var state: AgentAudioVisualizerAuraState = .connecting
    var color: String = "#3FD6F5"
    var colorShift: Float = 0.05
    var themeMode: AgentAudioVisualizerAuraThemeMode = .dark
    var shape: AgentAudioVisualizerAuraShape = .circle
    var blur: Float = 0.2
    /// Volume 0...1 (the agent's voice level) while `state` is `.speaking`.
    var volume: Double = 0
    var isStatic = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = isStatic || reduceMotion
        Group {
            if JarvisAuraShader.isSupported {
                JarvisAuraRepresentable(
                    state: state, volume: volume, isStatic: still,
                    style: JarvisAuraStyle(color: JarvisAuraStyle.rgb(hex: color), colorShift: colorShift,
                                           themeMode: themeMode, shape: shape, blur: blur)
                )
            } else {
                // No Metal device (some simulators): the brand mark instead of a blank screen.
                OrbitalCoreView(state: .idle, isStatic: true)
            }
        }
        .frame(width: size.points, height: size.points)
        .opacity(still ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

/// The voice screen's field: the Aura driven by the call.
struct JarvisAuraView: View {
    var phase: JarvisVoicePhase
    var volume: Double
    var size: AgentAudioVisualizerAuraSize = .custom(260)
    var isStatic = false

    var body: some View {
        AgentAudioVisualizerAura(size: size, state: phase.auraState, volume: volume, isStatic: isStatic)
    }
}

/// Everything about the look that is not animated.
struct JarvisAuraStyle: Equatable {
    var color: SIMD3<Float>
    var colorShift: Float
    var themeMode: AgentAudioVisualizerAuraThemeMode
    var shape: AgentAudioVisualizerAuraShape
    var blur: Float

    static let jarvis = JarvisAuraStyle(color: rgb(hex: "#3FD6F5"), colorShift: 0.05, themeMode: .dark,
                                        shape: .circle, blur: 0.2)

    /// `hexToRgb`: #RRGGBB to 0...1, falling back to LiveKit's #1FD5F9 when it doesn't parse.
    static func rgb(hex: String) -> SIMD3<Float> {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return rgb(hex: "#1FD5F9") }
        return SIMD3(Float((value >> 16) & 0xFF) / 255, Float((value >> 8) & 0xFF) / 255, Float(value & 0xFF) / 255)
    }
}

private struct JarvisAuraRepresentable: UIViewRepresentable {
    var state: AgentAudioVisualizerAuraState
    var volume: Double
    var isStatic: Bool
    var style: JarvisAuraStyle

    func makeUIView(context: Context) -> JarvisAuraMetalView {
        let view = JarvisAuraMetalView(frame: .zero, device: nil)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: JarvisAuraMetalView, context: Context) {
        view.style = style
        view.volume = volume
        view.isStatic = isStatic
        view.state = state
    }
}

// MARK: - Shader

/// Compiles the Aura shader once. Tests call this so a bad port fails CI, not a phone call.
enum JarvisAuraShader {
    static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "aura_vertex"),
              let fragment = library.makeFunction(name: "aura_fragment") else {
            throw JarvisAuraShaderError.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // The fragment colour is premultiplied by alpha, the way the WebGL canvas composites it
        // (premultipliedAlpha): result = src + (1 - srcAlpha) * dst.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum JarvisAuraShaderError: Error { case missingFunction }

    // swiftlint:disable line_length
    /// GLSL from agent-audio-visualizer-aura.tsx, translated to MSL one function at a time.
    /// Uniforms are five float4s: (time, speed, amplitude, frequency), (scale, shape, blur,
    /// colorShift), (brightness/uMix, spacing, variance, smoothing), (bloom, mode, resX, resY),
    /// (r, g, b, 0). GLSL `v * m` is MSL `v * m` (a row vector times a column-major matrix).
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct AuraUniforms {
        float4 a;
        float4 b;
        float4 c;
        float4 d;
        float4 e;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VOut aura_vertex(uint vid [[vertex_id]]) {
        float2 p[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        VOut o;
        o.position = float4(p[vid], 0.0, 1.0);
        o.uv = float2(p[vid].x * 0.5 + 0.5, p[vid].y * 0.5 + 0.5);
        return o;
    }

    constant float TAU = 6.283185;

    // Noise for dithering
    float2 randFibo(float2 p) {
        p = fract(p * float2(443.897, 441.423));
        p += dot(p, p.yx + 19.19);
        return fract((p.xx + p.yx) * p.xy);
    }

    // Tonemap
    float3 Tonemap(float3 x) {
        x *= 4.0;
        return x / (1.0 + x);
    }

    // Luma for alpha
    float luma(float3 color) { return dot(color, float3(0.299, 0.587, 0.114)); }

    // RGB to HSV
    float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
        float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    // HSV to RGB
    float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

    // SDF shapes
    float sdCircle(float2 st, float r) { return length(st) - r; }

    float sdLine(float2 p, float r) {
        float halfLen = r * 2.0;
        float2 a = float2(-halfLen, 0.0);
        float2 b = float2(halfLen, 0.0);
        float2 pa = p - a;
        float2 ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    float getSdf(float2 st, float uShape, float uScale) {
        if (uShape == 1.0) return sdCircle(st, uScale);
        else if (uShape == 2.0) return sdLine(st, uScale);
        return sdCircle(st, uScale); // Default
    }

    float2 turb(float2 pos, float t, float it, float uFrequency, float uAmplitude, float uSpeed, float uVariance) {
        // Initial rotation matrix for swirl direction: GLSL mat2(0.6, -0.25, 0.25, 0.9), column-major.
        float2x2 rotation = float2x2(float2(0.6, -0.25), float2(0.25, 0.9));
        // Secondary rotation applied each iteration (approx 53 degree rotation)
        float2x2 layerRotation = float2x2(float2(0.6, -0.8), float2(0.8, 0.6));

        float frequency = mix(2.0, 15.0, uFrequency);
        float amplitude = uAmplitude;
        float frequencyGrowth = 1.4;
        float animTime = t * 0.1 * uSpeed;

        for (int i = 0; i < 4; i++) {
            // Calculate wave displacement for this layer
            float2 rotatedPos = pos * rotation;
            float2 wave = sin(frequency * rotatedPos + float(i) * animTime + it);

            // Apply displacement along rotation direction
            pos += (amplitude / frequency) * rotation[0] * wave;

            // Evolve parameters for next layer
            rotation = rotation * layerRotation;
            amplitude *= mix(1.0, max(wave.x, wave.y), uVariance);
            frequency *= frequencyGrowth;
        }
        return pos;
    }

    fragment float4 aura_fragment(VOut in [[stage_in]], constant AuraUniforms &u [[buffer(0)]]) {
        float iTime = u.a.x;
        float uSpeed = u.a.y;
        float uAmplitude = u.a.z;
        float uFrequency = u.a.w;
        float uScale = u.b.x;
        float uShape = u.b.y;
        float uBlur = u.b.z;
        float uColorShift = u.b.w;
        float uMix = u.c.x;
        float uSpacing = u.c.y;
        float uVariance = u.c.z;
        float uSmoothing = u.c.w;
        float uBloom = u.d.x;
        float uMode = u.d.y;
        float2 iResolution = float2(u.d.z, u.d.w);
        float3 uColor = u.e.xyz;

        float2 fragCoord = in.uv * iResolution;
        float2 uv = fragCoord / iResolution;

        float3 pp = float3(0.0);
        float3 bloom = float3(0.0);
        float t = iTime * 0.5;
        float2 pos = uv - 0.5;

        const float ITERATIONS = 36.0;
        float2 prevPos = turb(pos, t, 0.0 - 1.0 / ITERATIONS, uFrequency, uAmplitude, uSpeed, uVariance);
        float spacing = mix(1.0, TAU, uSpacing);

        for (float i = 1.0; i < ITERATIONS + 1.0; i++) {
            float iter = i / ITERATIONS;
            float2 st = turb(pos, t, iter * spacing, uFrequency, uAmplitude, uSpeed, uVariance);
            float d = abs(getSdf(st, uShape, uScale));
            float pd = distance(st, prevPos);
            prevPos = st;
            float dynamicBlur = exp2(pd * 2.0 * 1.4426950408889634) - 1.0;
            float ds = smoothstep(0.0, uBlur * 0.05 + max(dynamicBlur * uSmoothing, 0.001), d);

            // Shift color based on iteration using uColorScale
            float3 color = uColor;
            if (uColorShift > 0.01) {
                float3 hsv = rgb2hsv(color);
                // Shift hue by iteration
                hsv.x = fract(hsv.x + (1.0 - iter) * uColorShift * 0.3);
                color = hsv2rgb(hsv);
            }

            float invd = 1.0 / max(d + dynamicBlur, 0.001);
            pp += (ds - 1.0) * color;
            bloom += clamp(invd, 0.0, 250.0) * color;
        }

        pp *= 1.0 / ITERATIONS;

        float3 color;
        float alpha;

        // Dark mode (default)
        if (uMode < 0.5) {
            // use bloom effect
            bloom = bloom / (bloom + 2e4);
            color = (-pp + bloom * 3.0 * uBloom) * 1.2;
            color += (randFibo(fragCoord).x - 0.5) / 255.0;
            color = Tonemap(color);
            alpha = luma(color) * uMix;
            color = color * uMix;
        }
        // Light mode
        else {
            // no bloom effect
            color = -pp;
            color += (randFibo(fragCoord).x - 0.5) / 255.0;

            // Preserve hue by tone mapping brightness only
            float brightness = length(color);
            float3 direction = brightness > 0.0 ? color / brightness : color;

            // Reinhard on brightness
            float factor = 2.0;
            float mappedBrightness = (brightness * factor) / (1.0 + brightness * factor);
            color = direction * mappedBrightness;

            // Boost saturation to compensate for white background bleed-through
            float gray = dot(color, float3(0.2, 0.5, 0.1));
            float saturationBoost = 3.0;
            color = mix(float3(gray), color, saturationBoost);

            // Clamp between 0-1
            color = clamp(color, 0.0, 1.0);

            alpha = mappedBrightness * clamp(uMix, 1.0, 2.0);
        }
        return float4(color, alpha);
    }
    """
}

// MARK: - Metal view

final class JarvisAuraMetalView: MTKView, MTKViewDelegate {
    var style = JarvisAuraStyle.jarvis
    var volume: Double = 0
    var state: AgentAudioVisualizerAuraState = .idle {
        didSet { animator.apply(state: state, now: CACurrentMediaTime() - started) }
    }
    /// Reduce Motion: one still frame, no display link.
    var isStatic = false {
        didSet {
            guard isStatic != oldValue else { return }
            applyPausing()
            setNeedsDisplay()
        }
    }

    private var animator = JarvisAuraAnimator()
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private let started = CACurrentMediaTime()
    private var inForeground = true
    private var observers: [NSObjectProtocol] = []

    /// The time of the still frame: any moment of the swirl, picked to look settled.
    private static let stillTime: Float = 7

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let gpu = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: gpu)
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 30
        delegate = self
        applyPausing()
        if let gpu {
            queue = gpu.makeCommandQueue()
            do {
                pipeline = try JarvisAuraShader.makePipeline(device: gpu)
            } catch {
                JarvisClientLog.record("voice", "aura shader did not compile: \(error)")
            }
        }
        // No GPU work from the background: a call keeps running, the picture waits.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.inForeground = false
            self?.applyPausing()
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.inForeground = true
            self?.applyPausing()
        })
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func applyPausing() {
        // Still frames are drawn on demand; moving ones on the display link while in the foreground.
        enableSetNeedsDisplay = isStatic
        isPaused = isStatic || !inForeground
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The web version caps its pixel ratio at 2 (the loop is 36 turbulence passes per pixel).
        let screenScale = min(2, window?.screen.scale ?? traitCollection.displayScale)
        let side = max(1, min(400, (bounds.width * screenScale).rounded()))
        let size = CGSize(width: side, height: side)
        if drawableSize != size { drawableSize = size }
        if isStatic { setNeedsDisplay() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline, let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = queue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let time: Float
        let values: JarvisAuraValues
        if isStatic {
            time = Self.stillTime
            values = JarvisAuraAnimator.values(for: .idle)
        } else {
            let now = CACurrentMediaTime() - started
            time = Float(now)
            values = animator.values(now: now, volume: volume)
        }
        var uni = uniforms(time: time, values: values)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uni, length: MemoryLayout<SIMD4<Float>>.stride * uni.count, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The same uniforms AuraShader hands ReactShaderToy: uBloom 0, uSpacing 0.5, uVariance 0.1,
    /// uSmoothing 1, uMix = brightness.
    private func uniforms(time: Float, values: JarvisAuraValues) -> [SIMD4<Float>] {
        let side = Float(drawableSize.width)
        return [
            SIMD4(time, values.speed, values.amplitude, values.frequency),
            SIMD4(values.scale, style.shape.rawValue, style.blur, style.colorShift),
            SIMD4(values.brightness, 0.5, 0.1, 1),
            SIMD4(0, style.themeMode.rawValue, side, side),
            SIMD4(style.color.x, style.color.y, style.color.z, 0)
        ]
    }
}
