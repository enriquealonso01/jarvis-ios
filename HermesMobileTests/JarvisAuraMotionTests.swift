import Metal
import XCTest
@testable import HermesMobile

final class JarvisAuraMotionTests: XCTestCase {
    func testIdleAndAFailedCallHoldStill() {
        let idle = JarvisAuraMotion.targets(phase: .ready, volume: 0, muted: false)
        XCTAssertEqual(idle.speed, 10)
        XCTAssertEqual(idle.scale, 0.2)
        XCTAssertNil(idle.brightnessPulse)
        XCTAssertEqual(JarvisAuraMotion.targets(phase: .failed("failed: down"), volume: 1, muted: false).speed, 10)
    }

    func testListeningPulsesAndThinkingMovesFaster() {
        let listening = JarvisAuraMotion.targets(phase: .listening, volume: 0, muted: false)
        XCTAssertEqual(listening.speed, 20)
        XCTAssertEqual(listening.brightnessPulse, 2)
        let thinking = JarvisAuraMotion.targets(phase: .thinking, volume: 0, muted: false)
        XCTAssertEqual(thinking.speed, 30)
        XCTAssertEqual(JarvisAuraMotion.targets(phase: .connecting, volume: 0, muted: false).speed, 30)
    }

    func testSpeakingGrowsWithJarvisVoiceLevelAndMuteHoldsStill() {
        let quiet = JarvisAuraMotion.targets(phase: .speaking, volume: 0, muted: false)
        XCTAssertEqual(quiet.speed, 70)
        XCTAssertEqual(quiet.scale, 0.3)
        let loud = JarvisAuraMotion.targets(phase: .speaking, volume: 1, muted: false)
        XCTAssertEqual(loud.scale, 0.4, accuracy: 0.0001)
        let muted = JarvisAuraMotion.targets(phase: .speaking, volume: 1, muted: true)
        XCTAssertEqual(muted.speed, 10)
        XCTAssertEqual(muted.scale, 0.2)
    }

    func testTheAuraShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("This machine has no Metal device")
        }
        _ = try JarvisAuraShader.makePipeline(device: device)
    }
}
