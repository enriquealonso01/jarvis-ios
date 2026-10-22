import SwiftUI
import MetalKit

/// Where the Aura field settles for a call phase. The numbers are LiveKit's
/// `useAgentAudioVisualizerAura` (Apache-2.0): speed, scale, amplitude, frequency,
/// and a brightness that either holds or pulses between two values.
struct JarvisAuraTargets: Equatable {
    var speed: Float
    var scale: Float
    var amplitude: Float
    var frequency: Float
    var brightness: Float
    var brightnessPulse: Float?
}

/// LiveKit's Aura motion, driven by the call instead of an AgentState.
enum JarvisAuraMotion {
    /// Jarvis Cyan #3FD6F5. LiveKit's default is #1FD5F9; this is the brand accent.
    static let color = SIMD3<Float>(63.0 / 255, 214.0 / 255, 245.0 / 255)
    static let colorShift: Float = 0.05

    static func targets(phase: JarvisVoicePhase, volume: Double, muted: Bool) -> JarvisAuraTargets {
        if muted { return idle }
        switch phase {
        case .ready, .failed:
            return idle
        case .listening:
            return JarvisAuraTargets(speed: 20, scale: 0.3, amplitude: 1.0, frequency: 0.7,
                                     brightness: 1.5, brightnessPulse: 2.0)
        case .connecting, .thinking:
            return JarvisAuraTargets(speed: 30, scale: 0.3, amplitude: 0.5, frequency: 1.0,
                                     brightness: 0.5, brightnessPulse: 2.5)
        case .speaking:
            let level = Float(min(1, max(0, volume)))
            let scale: Float = level > 0 ? 0.2 + 0.2 * level : 0.3
            return JarvisAuraTargets(speed: 70, scale: scale, amplitude: 0.75, frequency: 1.25,
                                     brightness: 1.5, brightnessPulse: nil)
        }
    }

    private static let idle = JarvisAuraTargets(speed: 10, scale: 0.2, amplitude: 1.2, frequency: 0.4,
                                                brightness: 1.0, brightnessPulse: nil)
}

/// The voice screen's field. A port of LiveKit's AgentAudioVisualizerAura shader
/// (Apache-2.0, livekit/components-js), drawn in Jarvis Cyan and wired to the call.
struct JarvisAuraView: UIViewRepresentable {
    var phase: JarvisVoicePhase
    var volume: Double

    func makeUIView(context: Context) -> JarvisAuraMetalView {
        let view = JarvisAuraMetalView(frame: .zero, device: nil)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: JarvisAuraMetalView, context: Context) {
        view.targets = JarvisAuraMotion.targets(phase: phase, volume: volume, muted: false)
    }
}

/// Compiles the Aura shader once. Tests call this so a bad port fails CI, not a phone call.
enum JarvisAuraShader {
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
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    enum JarvisAuraShaderError: Error { case missingFunction }

    // swiftlint:disable line_length
    /// GLSL from agent-audio-visualizer-aura.tsx, rewritten as MSL. Uniforms are five
    /// float4s: (time, speed, amplitude, frequency), (scale, shape, blur, colorShift),
    /// (brightness, spacing, variance, smoothing), (bloom, mode, resX, resY), (r, g, b, 0).
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

    float2 rowMul(float2 v, float2x2 m) {
        float2 c0 = m[0];
        float2 c1 = m[1];
        return float2(dot(v, float2(c0.x, c1.x)), dot(v, float2(c0.y, c1.y)));
    }

    float2 randFibo(float2 p) {
        p = fract(p * float2(443.897, 441.423));
        p += dot(p, p.yx + 19.19);
        return fract((p.xx + p.yx) * p.xy);
    }

    float3 tonemap(float3 x) {
        x *= 4.0;
        return x / (1.0 + x);
    }

    float luma(float3 color) { return dot(color, float3(0.299, 0.587, 0.114)); }

    float3 rgb2hsv(float3 c) {
        float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
        float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
        float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
        float d = q.x - min(q.w, q.y);
        float e = 1.0e-10;
        return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
    }

    float3 hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

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

    float2 turb(float2 pos, float t, float it, float uFrequency, float uAmplitude, float uSpeed, float uVariance) {
        float2x2 rotation = float2x2(float2(0.6, -0.25), float2(0.25, 0.9));
        float2x2 layerRotation = float2x2(float2(0.6, -0.8), float2(0.8, 0.6));
        float frequency = mix(2.0, 15.0, uFrequency);
        float amplitude = uAmplitude;
        float frequencyGrowth = 1.4;
        float animTime = t * 0.1 * uSpeed;
        for (int i = 0; i < 4; i++) {
            float2 rotatedPos = rowMul(pos, rotation);
            float2 wave = sin(frequency * rotatedPos + float(i) * animTime + it);
            pos += (amplitude / frequency) * rotation[0] * wave;
            rotation = rotation * layerRotation;
            amplitude *= mix(1.0, max(wave.x, wave.y), uVariance);
            frequency *= frequencyGrowth;
        }
        return pos;
    }

    fragment float4 aura_fragment(VOut in [[stage_in]], constant AuraUniforms &u [[buffer(0)]]) {
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
        float iTime = u.a.x;
        float2 fragCoord = in.uv * iResolution;

        float3 pp = float3(0.0);
        float3 bloom = float3(0.0);
        float t = iTime * 0.5;
        float2 pos = in.uv - 0.5;
        const float ITERATIONS = 36.0;
        float2 prevPos = turb(pos, t, 0.0 - 1.0 / ITERATIONS, uFrequency, uAmplitude, uSpeed, uVariance);
        float spacing = mix(1.0, 6.283185, uSpacing);

        for (int i = 1; i <= 36; i++) {
            float iter = float(i) / ITERATIONS;
            float2 st = turb(pos, t, iter * spacing, uFrequency, uAmplitude, uSpeed, uVariance);
            float d = (uShape == 2.0) ? abs(sdLine(st, uScale)) : abs(sdCircle(st, uScale));
            float pd = distance(st, prevPos);
            prevPos = st;
            float dynamicBlur = exp2(pd * 2.0 * 1.4426950408889634) - 1.0;
            float ds = smoothstep(0.0, uBlur * 0.05 + max(dynamicBlur * uSmoothing, 0.001), d);
            float3 color = uColor;
            if (uColorShift > 0.01) {
                float3 hsv = rgb2hsv(color);
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
        if (uMode < 0.5) {
            bloom = bloom / (bloom + 2e4);
            color = (-pp + bloom * 3.0 * uBloom) * 1.2;
            color += (randFibo(fragCoord).x - 0.5) / 255.0;
            color = tonemap(color);
            alpha = luma(color) * uMix;
            color *= uMix;
        } else {
            color = -pp;
            color += (randFibo(fragCoord).x - 0.5) / 255.0;
            float brightness = length(color);
            float3 direction = brightness > 0.0 ? color / brightness : color;
            float mapped = (brightness * 2.0) / (1.0 + brightness * 2.0);
            color = direction * mapped;
            float gray = dot(color, float3(0.2, 0.5, 0.1));
            color = clamp(mix(float3(gray), color, 3.0), 0.0, 1.0);
            alpha = mapped * clamp(uMix, 1.0, 2.0);
        }
        return float4(color, alpha);
    }
    """
}

final class JarvisAuraMetalView: MTKView, MTKViewDelegate {
    var targets = JarvisAuraMotion.targets(phase: .ready, volume: 0, muted: false)
    private var speed: Float = 10
    private var scale: Float = 0.2
    private var amplitude: Float = 1.2
    private var frequency: Float = 0.4
    private var brightness: Float = 1
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var started = CACurrentMediaTime()
    private var lastDraw = CACurrentMediaTime()

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let gpu = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: gpu)
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 30
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        delegate = self
        if let gpu {
            queue = gpu.makeCommandQueue()
            do {
                pipeline = try JarvisAuraShader.makePipeline(device: gpu)
            } catch {
                JarvisClientLog.record("voice", "aura shader did not compile: \(error)")
            }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(2, window?.screen.scale ?? traitCollection.displayScale)
        let side = max(1, min(400, bounds.width * scale))
        let size = CGSize(width: side, height: side)
        if drawableSize != size { drawableSize = size }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = queue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastDraw))
        lastDraw = now
        approach(&speed, targets.speed, dt)
        approach(&scale, targets.scale, dt)
        approach(&amplitude, targets.amplitude, dt)
        approach(&frequency, targets.frequency, dt)
        let pulse = targets.brightnessPulse
        let brightnessTarget = pulse.map { targets.brightness + ( $0 - targets.brightness) * Float(0.5 + 0.5 * sin(now * 3)) } ?? targets.brightness
        approach(&brightness, brightnessTarget, pulse == nil ? dt : 1)
        if let pipeline {
            var uni = uniforms(time: Float(now - started))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uni, length: MemoryLayout<SIMD4<Float>>.stride * uni.count, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func approach(_ value: inout Float, _ target: Float, _ dt: Float) {
        let k = min(1, dt / 0.5)
        value += (target - value) * k
    }

    private func uniforms(time: Float) -> [SIMD4<Float>] {
        let color = JarvisAuraMotion.color
        let side = Float(drawableSize.width)
        return [
            SIMD4(time, speed, amplitude, frequency),
            SIMD4(scale, 1, 1, JarvisAuraMotion.colorShift),
            SIMD4(brightness, 0.5, 0.1, 1),
            SIMD4(0, 0, side, side),
            SIMD4(color.x, color.y, color.z, 0),
        ]
    }
}
