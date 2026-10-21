import XCTest
@testable import HermesMobile

/// The phone's failure log JARVIS reads beside the server's logs (requirement 9).
@MainActor final class JarvisClientLogTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "JarvisClientLogTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testTodaysEntriesBecomeJSONLines() throws {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        JarvisClientLog.record("http", "GET failed: URLError -1001", path: "/api/sessions", now: yesterday, defaults: defaults)
        JarvisClientLog.record("call", "call failed: ICE failed", now: now, defaults: defaults)
        let lines = JarvisClientLog.fileText(for: now, defaults: defaults).split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "only today's entries go in today's file")
        let entry = try JSONDecoder().decode(JarvisClientLog.Entry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(entry.cat, "call")
        XCTAssertEqual(entry.msg, "call failed: ICE failed")
        XCTAssertTrue(JarvisClientLog.filePath(for: now).hasPrefix("~/.jarvis-ios/logs/"))
        XCTAssertTrue(JarvisClientLog.filePath(for: now).hasSuffix(".jsonl"))
    }

    func testKeepsTheNewestEntriesOnly() {
        for index in 0..<(JarvisClientLog.limit + 5) {
            JarvisClientLog.record("http", "failure \(index)", defaults: defaults)
        }
        let lines = JarvisClientLog.fileText(defaults: defaults).split(separator: "\n")
        XCTAssertEqual(lines.count, JarvisClientLog.limit)
        XCTAssertTrue(lines.last?.contains("failure \(JarvisClientLog.limit + 4)") ?? false)
    }

    func testUserAgentNamesTheApp() {
        XCTAssertTrue(JarvisClientLog.userAgent.hasPrefix("JARVIS-iOS/"))
    }
}
