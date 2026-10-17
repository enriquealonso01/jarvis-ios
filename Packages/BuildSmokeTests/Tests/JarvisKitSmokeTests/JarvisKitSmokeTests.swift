import XCTest
@testable import JarvisKit

/// Item 0 smoke: JarvisKit exposes its public API surface. Compile-time
/// imports are exercised by this file existing; each core type gets one smoke
/// instantiation so a public-init regression (or an accidental access-level
/// tightening) fails here immediately.
final class JarvisKitSmokeTests: XCTestCase {
    func testCoreTypesInstantiate() throws {
        // ServerConfig
        let cfg = ServerConfig(baseURL: URL(string: "https://jarvis.local")!)
        XCTAssertNotNil(cfg.url("/api/health"))

        // Conversation
        let conv = Conversation(title: "smoke")
        XCTAssertFalse(conv.pendingSync)

        // MessageRole + Message
        let msg = Message(conversationID: conv.id, role: .assistant, text: "hi")
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.branchIndex, 0)

        // AgentEvent
        let ev = AgentEvent(id: 1, kind: "token", payload: "x")
        XCTAssertEqual(ev.id, 1)

        // Round-trip Codable (Sendable + Codable are part of the v2 API contract)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded, msg)
    }

    func testAPIClientActorIsPubliclyConstructible() async {
        // APIClient is an actor — construct + setToken proves the public
        // surface crosses isolation correctly; no network is performed.
        let client = APIClient(config: ServerConfig(baseURL: URL(string: "https://jarvis.local")!))
        await client.setToken("smoke-token")
        _ = client // keep alive past the await
    }

    func testSSEClientParsesPublicEventShape() throws {
        let ev = try XCTUnwrap(SSEClient.parseEvent(
            #"data: {"id": 3, "kind": "run_status", "payload": "{}"}"#))
        XCTAssertEqual(ev.kind, "run_status")
        XCTAssertNil(SSEClient.parseEvent("event: ping"))
    }

    func testKeychainInMemoryFallbackSurface() {
        // Keychain (Security) calls don't run on Linux CI; the in-memory
        // fallback mirrors the public token-store shape.
        var store = InMemoryTokenStore()
        store.set("tok", forKey: "hermes")
        XCTAssertEqual(store.get("hermes"), "tok")
        store.remove("hermes")
        XCTAssertNil(store.get("hermes"))
    }
}
