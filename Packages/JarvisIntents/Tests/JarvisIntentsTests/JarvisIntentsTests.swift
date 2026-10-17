import Foundation
import XCTest

@testable import JarvisIntents

final class JarvisIntentsTests: XCTestCase {
    func testCallLink() {
        XCTAssertEqual(DeepLink.parse(URL(string: "jarvis://call")!), .startCall)
    }

    func testChatLinkWithUUID() {
        let id = UUID()
        XCTAssertEqual(DeepLink.parse(URL(string: "jarvis://chat/\(id.uuidString)")!), .chat(conversationID: id))
    }

    func testRunLink() {
        let id = UUID()
        XCTAssertEqual(DeepLink.parse(URL(string: "jarvis://run/\(id.uuidString)")!), .run(runID: id))
    }

    func testUnknownLinks() {
        XCTAssertEqual(DeepLink.parse(URL(string: "jarvis://nonsense/abc")!), .unknown)
        XCTAssertEqual(DeepLink.parse(URL(string: "https://example.com/call")!), .unknown)
    }
}
