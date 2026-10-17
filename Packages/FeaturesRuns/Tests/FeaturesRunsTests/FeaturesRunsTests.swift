import XCTest

@testable import FeaturesRuns

final class FeaturesRunsTests: XCTestCase {
    func testProgressLabelAndCompletion() {
        var run = AgentRun(title: "Krendora orders", steps: [
            RunStep(id: 1, title: "fetch cart"),
            RunStep(id: 2, title: "check stock"),
        ])
        XCTAssertEqual(run.progressLabel, "Krendora orders — step 0/2")
        run.completeStep(1)
        XCTAssertEqual(run.phase, .running)
        run.completeStep(2)
        XCTAssertEqual(run.phase, .done)
        XCTAssertEqual(run.progressLabel, "Krendora orders — step 2/2")
    }

    func testPhaseCodableRoundTrip() throws {
        let phase = RunPhase.needsApproval
        let data = try JSONEncoder().encode(phase)
        XCTAssertEqual(try JSONDecoder().decode(RunPhase.self, from: data), phase)
    }
}
