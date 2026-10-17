import Foundation
import XCTest

@testable import JarvisKit

final class JarvisKitTests: XCTestCase {
    func testMessageDefaults() {
        let conv = Conversation(title: "test")
        let msg = Message(conversationID: conv.id, role: .user, text: "hello")
        XCTAssertEqual(msg.role, .user)
        XCTAssertFalse(msg.pendingSync)
        XCTAssertEqual(msg.branchIndex, 0)
    }

    func testServerConfigURLJoins() {
        let cfg = ServerConfig(baseURL: URL(string: "https://jarvis.example.com")!)
        XCTAssertEqual(cfg.url("/api/health")?.absoluteString, "https://jarvis.example.com/api/health")
        XCTAssertNil(cfg.url("ht tp://bad url"))
    }

    func testSSEParseEvent() throws {
        let line = #"data: {"id": 7, "kind": "token", "payload": "hello"}"#
        let ev = try XCTUnwrap(SSEClient.parseEvent(line))
        XCTAssertEqual(ev.id, 7)
        XCTAssertEqual(ev.kind, "token")
        XCTAssertEqual(ev.payload, "hello")
    }

    func testSSEParseIgnoresNonDataLines() {
        XCTAssertNil(SSEClient.parseEvent(": keepalive"))
        XCTAssertNil(SSEClient.parseEvent("event: token"))
        XCTAssertNil(SSEClient.parseEvent("data: not-json"))
    }

    func testInMemoryTokenStore() {
        var store = InMemoryTokenStore()
        store.set("tok1", forKey: "api")
        XCTAssertEqual(store.get("api"), "tok1")
        store.remove("api")
        XCTAssertNil(store.get("api"))
    }

    func testAPIErrorEquatable() {
        XCTAssertEqual(APIError.badStatus(401), APIError.badStatus(401))
        XCTAssertNotEqual(APIError.badURL("/x"), APIError.badStatus(401))
    }
}
