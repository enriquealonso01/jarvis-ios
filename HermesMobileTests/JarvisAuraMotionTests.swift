import Metal
import XCTest
@testable import HermesMobile

final class JarvisAuraMotionTests: XCTestCase {
    // MARK: state -> values (useAgentAudioVisualizerAura)

    func testIdleAndAFailedCallSettleToTheIdleValues() {
        for state in [AgentAudioVisualizerAuraState.idle, .failed, .disconnected] {
            let v = JarvisAuraAnimator.values(for: state)
            XCTAssertEqual(v, JarvisAuraValues(speed: 10, scale: 0.2, amplitude: 1.2, frequency: 0.4, brightness: 1.0))
        }
    }

    func testListeningSettlesAndPulsesItsBrightnessBetweenTheHooksTwoValues() {
        var animator = JarvisAuraAnimator()
        animator.apply(state: .listening, now: 0)
        let settled = animator.values(now: 5, volume: 0)
        XCTAssertEqual(settled.speed, 20)
        XCTAssertEqual(settled.scale, 0.3, accuracy: 0.001)
        XCTAssertEqual(settled.amplitude, 1.0, accuracy: 0.001)
        XCTAssertEqual(settled.frequency, 0.7, accuracy: 0.001)
        // The pulse starts at 1.5, reaches 2.0 after one 0.35 s leg and mirrors back.
        XCTAssertEqual(animator.values(now: 0, volume: 0).brightness, 1.5, accuracy: 0.001)
        XCTAssertEqual(animator.values(now: 0.35, volume: 0).brightness, 2.0, accuracy: 0.01)
        XCTAssertEqual(animator.values(now: 0.7, volume: 0).brightness, 1.5, accuracy: 0.01)
        for step in 0..<40 {
            let b = animator.values(now: Double(step) * 0.05, volume: 0).brightness
            XCTAssertTrue((1.49...2.01).contains(b), "brightness \(b) left the pulse range")
        }
    }

    func testConnectingAndThinkingMoveFasterAndPulseWide() {
        for state in [AgentAudioVisualizerAuraState.connecting, .initializing, .thinking] {
            var animator = JarvisAuraAnimator()
            animator.apply(state: state, now: 0)
            let v = animator.values(now: 5, volume: 0)
            XCTAssertEqual(v.speed, 30)
            XCTAssertEqual(v.amplitude, 0.5, accuracy: 0.001)
            XCTAssertEqual(v.frequency, 1.0, accuracy: 0.001)
            XCTAssertEqual(animator.values(now: 0, volume: 0).brightness, 0.5, accuracy: 0.001)
            XCTAssertEqual(animator.values(now: 0.35, volume: 0).brightness, 2.5, accuracy: 0.01)
        }
    }

    func testSpeakingFollowsTheVoiceLevelOnlyAfterItsScaleTransitionEnds() {
        var animator = JarvisAuraAnimator()
        animator.apply(state: .listening, now: 0)
        _ = animator.values(now: 5, volume: 0)
        animator.apply(state: .speaking, now: 5)
        // Within the 0.5 s transition the scale eases toward 0.3 and ignores the level.
        let early = animator.values(now: 5.2, volume: 1)
        XCTAssertEqual(early.speed, 70)
        XCTAssertLessThan(early.scale, 0.3 + 0.001)
        // After it, scale = 0.2 + 0.2 * volume, set at once.
        XCTAssertEqual(animator.values(now: 5.6, volume: 1).scale, 0.4, accuracy: 0.0001)
        XCTAssertEqual(animator.values(now: 5.7, volume: 0.5).scale, 0.3, accuracy: 0.0001)
        let v = animator.values(now: 6, volume: 0.5)
        XCTAssertEqual(v.amplitude, 0.75, accuracy: 0.001)
        XCTAssertEqual(v.frequency, 1.25, accuracy: 0.001)
        XCTAssertEqual(v.brightness, 1.5, accuracy: 0.001)
    }

    func testVoiceLevelDoesNothingOutsideSpeaking() {
        var animator = JarvisAuraAnimator()
        animator.apply(state: .listening, now: 0)
        XCTAssertEqual(animator.values(now: 5, volume: 1).scale, 0.3, accuracy: 0.001)
    }

    func testEasingEndpointsAndMonotonicEaseOut() {
        XCTAssertEqual(JarvisAuraEasing.easeOut(0), 0)
        XCTAssertEqual(JarvisAuraEasing.easeOut(1), 1)
        var previous = 0.0
        for step in 1...20 {
            let value = JarvisAuraEasing.easeOut(Double(step) / 20)
            XCTAssertGreaterThan(value, previous)
            previous = value
        }
        XCTAssertGreaterThan(JarvisAuraEasing.easeOut(0.5), 0.5, "ease-out is front-loaded")
        // The listening spring overshoots a little (bounce 0.35) and lands on 1.
        let peak = stride(from: 0.0, through: 1.0, by: 0.02).map { JarvisAuraEasing.spring($0, duration: 1, bounce: 0.35) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.0)
        XCTAssertEqual(JarvisAuraEasing.spring(1, duration: 1, bounce: 0.35), 1)
    }

    func testPhasesMapToLiveKitAgentStates() {
        XCTAssertEqual(JarvisVoicePhase.ready.auraState, .idle)
        XCTAssertEqual(JarvisVoicePhase.failed("failed: x").auraState, .failed)
        XCTAssertEqual(JarvisVoicePhase.connecting.auraState, .connecting)
        XCTAssertEqual(JarvisVoicePhase.listening.auraState, .listening)
        XCTAssertEqual(JarvisVoicePhase.thinking.auraState, .thinking)
        XCTAssertEqual(JarvisVoicePhase.speaking.auraState, .speaking)
    }

    func testJarvisCyanAndTheFallbackColour() {
        let cyan = JarvisAuraStyle.rgb(hex: "#3FD6F5")
        XCTAssertEqual(cyan.x, 63.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(cyan.y, 214.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(cyan.z, 245.0 / 255, accuracy: 0.0001)
        // hexToRgb falls back to LiveKit's default, #1FD5F9, for anything it can't parse.
        XCTAssertEqual(JarvisAuraStyle.rgb(hex: "teal"), JarvisAuraStyle.rgb(hex: "#1FD5F9"))
    }

    // MARK: shader

    func testTheAuraShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("This machine has no Metal device")
        }
        _ = try JarvisAuraShader.makePipeline(device: device)
    }

    /// The port keeps the original's pieces: 4 turbulence layers, 36 iterations, the matrix
    /// products in GLSL's `v * m` order, and the premultiplied blend.
    func testTheShaderKeepsTheOriginalsStructure() {
        let source = JarvisAuraShader.source
        XCTAssertTrue(source.contains("float2 rotatedPos = pos * rotation;"))
        XCTAssertTrue(source.contains("rotation = rotation * layerRotation;"))
        XCTAssertTrue(source.contains("const float ITERATIONS = 36.0;"))
        XCTAssertTrue(source.contains("for (int i = 0; i < 4; i++)"))
        XCTAssertTrue(source.contains("exp2(pd * 2.0 * 1.4426950408889634) - 1.0"))
        XCTAssertTrue(source.contains("bloom = bloom / (bloom + 2e4);"))
    }

    /// Renders one frame off-screen and checks there is cyan light in it, not a black square.
    func testTheShaderDrawsCyanLightFromTheCentre() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("This machine has no Metal device")
        }
        let pipeline = try JarvisAuraShader.makePipeline(device: device)
        let side = 64
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw XCTSkip("No texture") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw XCTSkip("No encoder")
        }
        let color = JarvisAuraStyle.rgb(hex: "#3FD6F5")
        var uniforms: [SIMD4<Float>] = [
            SIMD4(7, 20, 1.0, 0.7), SIMD4(0.3, 1, 0.2, 0.05), SIMD4(1.5, 0.5, 0.1, 1),
            SIMD4(0, 0, Float(side), Float(side)), SIMD4(color.x, color.y, color.z, 0)
        ]
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        texture.getBytes(&pixels, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        var red = 0.0, blue = 0.0, lit = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let b = Double(pixels[index]), r = Double(pixels[index + 2])
            blue += b
            red += r
            if pixels[index + 3] > 8 { lit += 1 }
        }
        XCTAssertGreaterThan(lit, side * side / 50, "the aura drew almost nothing")
        XCTAssertGreaterThan(blue, red * 1.1, "the aura is not cyan: blue \(blue), red \(red)")
    }
}
