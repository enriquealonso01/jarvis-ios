import CryptoKit
import XCTest
@testable import HermesMobile

/// Approvals: decoding what `/bridge/approvals` lists, the order of the page, the canonical message
/// the owner's signature covers (against signatures another implementation made), the answer's request
/// body, the pending count and the countdown chip.
@MainActor
final class JarvisApprovalsTests: XCTestCase {
    private let listing = Data("""
        {"ok": true, "count": 2, "now": 1794500000.1, "key_fingerprint": "65b6-0673-d6ed-884b", "alert_registered": true,
         "pending": [
          {"id": "A-1042", "project": "krendora", "project_name": "Krendora", "type": "krendora.free-dead-channel",
           "subject": "jamie_fry", "adhoc": false, "kind": "decision", "title": "Free product from dead channel @jamie_fry",
           "evidence": "Instagram blocked since Nov 10 · 31 posts queued", "evidence_source": "system",
           "links": [{"label": "Open AutoDS login", "url": "https://auth.autods.com/login"}, {"label": "Bad", "url": "javascript:alert(1)"}],
           "input": null, "created_at": 1794499000.0, "deadline_at": 1794517100.0, "state": "pending", "decided_at": null,
           "decided_via": null, "note": null, "result": null, "outcome": null, "can_retry": false,
           "session": {"id": "20261112_160419_ce1fd0", "profile": "krendora", "source": "hermex"}, "runs_action": true},
          {"id": "A-1043", "project": "tft", "project_name": "Ticketflipping", "type": "tft.reconnect-autods", "subject": "",
           "adhoc": true, "kind": "action", "title": "Reconnect AutoDS", "evidence": "Agent wrote this", "evidence_source": "agent",
           "links": [], "input": {"label": "Paste the address the browser lands on", "placeholder": "http://localhost:2048/callback?code=",
           "required": true, "mismatch": "That is not the callback address."}, "created_at": 1794499500.0,
           "deadline_at": 1794503000.0, "state": "pending"}
         ],
         "recent": [
          {"id": "A-1001", "project_name": "Krendora", "title": "Old one", "state": "failed", "decided_at": 1794400000.0,
           "outcome": "The run failed", "can_retry": true},
          {"id": "A-1002", "project_name": "Krendora", "title": "Newer", "state": "approved", "decided_at": 1794450000.0,
           "result": "released, 31 posts cancelled"}
         ]}
        """.utf8)

    // MARK: Decoding

    func testFullPayloadDecodes() throws {
        let snapshot = try JarvisApprovals.snapshot(from: listing)
        XCTAssertEqual(snapshot.keyFingerprint, "65b6-0673-d6ed-884b")
        XCTAssertTrue(snapshot.alertRegistered)
        XCTAssertEqual(snapshot.now, Date(timeIntervalSince1970: 1794500000.1))
        XCTAssertEqual(snapshot.pending.map(\.id), ["A-1042", "A-1043"])
        let first = snapshot.pending[0]
        XCTAssertEqual(first.kind, .decision)
        XCTAssertEqual(first.heading, "Krendora")
        XCTAssertFalse(first.evidenceFromAgent)
        XCTAssertEqual(first.links.map(\.label), ["Open AutoDS login"], "only http(s) links are kept")
        XCTAssertNil(first.input)
        XCTAssertEqual(first.session, JarvisApproval.Session(id: "20261112_160419_ce1fd0", profile: "krendora", source: "hermex"))
        XCTAssertEqual(first.deadline, Date(timeIntervalSince1970: 1794517100))
        let action = snapshot.pending[1]
        XCTAssertEqual(action.kind, .action)
        XCTAssertTrue(action.adhoc)
        XCTAssertTrue(action.evidenceFromAgent)
        XCTAssertEqual(action.input?.label, "Paste the address the browser lands on")
        XCTAssertEqual(action.input?.mismatch, "That is not the callback address.")
        XCTAssertEqual(action.subject, "")
        XCTAssertNil(action.session)
    }

    func testSparsePayloadDecodesWithDefaults() throws {
        let sparse = Data(#"{"pending": [{"id": "A-1"}, {"title": "no id"}, {"id": "  "}], "recent": []}"#.utf8)
        let snapshot = try JarvisApprovals.snapshot(from: sparse)
        XCTAssertEqual(snapshot.pending.count, 1)
        let item = snapshot.pending[0]
        XCTAssertEqual(item.title, "A-1")
        XCTAssertEqual(item.state, "pending")
        XCTAssertEqual(item.kind, .decision)
        XCTAssertEqual(item.type, "")
        XCTAssertNil(item.deadline)
        XCTAssertNil(item.evidence)
        XCTAssertFalse(item.canRetry)
        XCTAssertNil(snapshot.keyFingerprint)
        XCTAssertFalse(snapshot.alertRegistered)
        XCTAssertThrowsError(try JarvisApprovals.snapshot(from: Data("[]".utf8)))
    }

    // MARK: Order

    func testGroupsByProjectThenSoonestDeadline() throws {
        func item(_ id: String, project: String, deadline: Double?) -> JarvisApproval {
            let json = deadline.map { #"{"id": "\#(id)", "project_name": "\#(project)", "deadline_at": \#($0), "created_at": 1}"# }
                ?? #"{"id": "\#(id)", "project_name": "\#(project)", "created_at": 1}"#
            return JarvisApproval(json: try! JSONDecoder().decode(BotJSON.self, from: Data(json.utf8)))!
        }
        let groups = JarvisApprovals.groups([
            item("c", project: "Ticketflipping", deadline: 10), item("b", project: "Krendora", deadline: nil),
            item("a", project: "Krendora", deadline: 50), item("d", project: "Krendora", deadline: 20), item("e", project: "", deadline: 5)
        ])
        XCTAssertEqual(groups.map(\.name), ["Krendora", "Other", "Ticketflipping"])
        XCTAssertEqual(groups[0].items.map(\.id), ["d", "a", "b"])
        let recent = try JarvisApprovals.snapshot(from: listing).recent
        XCTAssertEqual(JarvisApprovals.recentOrder(recent).map(\.id), ["A-1002", "A-1001"])
        XCTAssertEqual(recent[0].summary, "The run failed")
        XCTAssertEqual(recent[1].summary, "released, 31 posts cancelled")
    }

    // MARK: Signing

    private let seed = Data((1...32).map { UInt8($0) })
    private let vectorInput = "http://localhost:2048/callback?code=abc123"

    private func vectorSigner() throws -> JarvisApprovalSigner {
        JarvisApprovalSigner(privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    func testKeyAndFingerprintMatchTheVector() throws {
        let signer = try vectorSigner()
        XCTAssertEqual(signer.publicKeyBase64, "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=")
        XCTAssertEqual(signer.fingerprint, "65b6-0673-d6ed-884b")
    }

    func testCanonicalMessageBytes() {
        XCTAssertEqual(JarvisApprovalSigner.inputDigest("  \(vectorInput)\n"),
                       "422c04873fd381b1b18f29b2b0cbe4559def443067cb9f420a08fdaedaa6ba00")
        XCTAssertEqual(JarvisApprovalSigner.inputDigest(nil), "-")
        XCTAssertEqual(JarvisApprovalSigner.inputDigest("   "), "-")
        let one = JarvisApprovalSigner.canonicalMessage(id: "A-1042", type: "krendora.autods-relogin", subject: "", decisionWord: "approve",
                                                        input: vectorInput, exp: 1_800_000_000)
        XCTAssertEqual(String(decoding: one, as: UTF8.self), """
            jarvis-approval-v1
            A-1042
            krendora.autods-relogin

            approve
            422c04873fd381b1b18f29b2b0cbe4559def443067cb9f420a08fdaedaa6ba00
            1800000000
            """)
        let two = JarvisApprovalSigner.canonicalMessage(id: "A-1043", type: "krendora.free-dead-channel", subject: "jamie_fry",
                                                        decisionWord: "deny", input: nil, exp: 1_800_000_000)
        XCTAssertEqual(String(decoding: two, as: UTF8.self),
                       "jarvis-approval-v1\nA-1043\nkrendora.free-dead-channel\njamie_fry\ndeny\n-\n1800000000")
        XCTAssertEqual(JarvisApprovals.Decision.retry.signedWord, "approve")
        XCTAssertEqual(JarvisApprovals.Decision.deny.signedWord, "deny")
    }

    func testPublicKeyVerifiesTheOtherImplementationsSignatures() throws {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: try vectorSigner().publicKey)
        let one = JarvisApprovalSigner.canonicalMessage(id: "A-1042", type: "krendora.autods-relogin", subject: "", decisionWord: "approve",
                                                        input: vectorInput, exp: 1_800_000_000)
        let two = JarvisApprovalSigner.canonicalMessage(id: "A-1043", type: "krendora.free-dead-channel", subject: "jamie_fry",
                                                        decisionWord: "deny", input: nil, exp: 1_800_000_000)
        let sigOne = try XCTUnwrap(Data(base64Encoded: "FFxsBUloDbnji9H0Wew/HPCDvuHJwFGRODti+0RPzC9aVAOxla9OwfwlbPsXdEJhw9I/pGSCT/g7iKU4mLnVCw=="))
        let sigTwo = try XCTUnwrap(Data(base64Encoded: "JHTUKsItjBB2YkthvwbKMjLJJAwMn/L+3QhQeDP9N9BnBCdvu8TDNxHpiGoyXftSCoUcEi3K/FBoQwrOLO1fBg=="))
        XCTAssertTrue(key.isValidSignature(sigOne, for: one))
        XCTAssertTrue(key.isValidSignature(sigTwo, for: two))
        XCTAssertFalse(key.isValidSignature(sigOne, for: two))
    }

    func testOwnSignatureVerifies() throws {
        let signer = try vectorSigner()
        let signature = try signer.sign(id: "A-1043", type: "krendora.free-dead-channel", subject: "jamie_fry", decision: .deny,
                                        input: nil, exp: 1_800_000_000)
        let message = JarvisApprovalSigner.canonicalMessage(id: "A-1043", type: "krendora.free-dead-channel", subject: "jamie_fry",
                                                            decisionWord: "deny", input: nil, exp: 1_800_000_000)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: signer.publicKey)
        XCTAssertTrue(key.isValidSignature(try XCTUnwrap(Data(base64Encoded: signature)), for: message))
    }

    // MARK: Request body

    func testDecisionBodyCarriesTheSignedFields() throws {
        let body = JarvisApprovals.decisionBody(decision: .approve, signature: "c2ln", exp: 1_800_000_600,
                                                input: "  \(vectorInput) \n", note: "  go ahead  ")
        XCTAssertEqual(body["decision"] as? String, "approve")
        XCTAssertEqual(body["signature"] as? String, "c2ln")
        XCTAssertEqual(body["exp"] as? Int, 1_800_000_600)
        XCTAssertEqual(body["input"] as? String, vectorInput)
        XCTAssertEqual(body["note"] as? String, "go ahead")
        let bare = JarvisApprovals.decisionBody(decision: .retry, signature: "c2ln", exp: 1, input: "  ", note: nil)
        XCTAssertEqual(bare["decision"] as? String, "retry")
        XCTAssertNil(bare["input"])
        XCTAssertNil(bare["note"])
        let long = JarvisApprovals.decisionBody(decision: .deny, signature: "c2ln", exp: 1, input: nil, note: String(repeating: "x", count: 400))
        XCTAssertEqual((long["note"] as? String)?.count, JarvisApprovals.noteLimit)
        XCTAssertEqual(JarvisApprovals.registerBody(alertToken: "ab12", signingKey: nil).keys.sorted(), ["alert_token"])
    }

    // MARK: Store

    private final class FakeAPI: JarvisApprovalsAPI {
        var snapshot: JarvisApprovals.Snapshot
        var refusal: JarvisApprovals.Refusal?
        var decided: [(id: String, body: [String: Any])] = []
        var registered: [(alert: String?, key: String?)] = []

        init(snapshot: JarvisApprovals.Snapshot) { self.snapshot = snapshot }

        func list() async throws -> JarvisApprovals.Snapshot { snapshot }

        func decide(id: String, body: [String: Any]) async throws -> JarvisApproval? {
            if let refusal { throw refusal }
            decided.append((id, body))
            let moved = snapshot.pending.first { $0.id == id }
            snapshot.pending.removeAll { $0.id == id }
            let state = body["decision"] as? String == "deny" ? "denied" : "approved"
            return JarvisApproval(json: .object(["id": .string(id), "title": .string(moved?.title ?? id), "state": .string(state)]))
        }

        func register(alertToken: String?, signingKey: String?) async throws {
            registered.append((alertToken, signingKey))
        }
    }

    private func makeStore(_ api: FakeAPI, badges: BadgeLog) -> JarvisApprovalsStore {
        JarvisApprovalsStore(api: api, signer: { try self.vectorSigner() }, setBadge: { badges.counts.append($0) },
                             defaults: UserDefaults(suiteName: "JarvisApprovalsTests")!)
    }

    private final class BadgeLog { var counts: [Int] = [] }

    func testPendingCountDrivesTheBadgeAndAnAnswerLowersIt() async throws {
        var snapshot = try JarvisApprovals.snapshot(from: listing)
        snapshot.keyFingerprint = "65b6-0673-d6ed-884b"
        let api = FakeAPI(snapshot: snapshot), badges = BadgeLog()
        let store = makeStore(api, badges: badges)
        await store.refresh()
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertEqual(store.groups.map(\.name), ["Krendora", "Ticketflipping"])
        XCTAssertEqual(badges.counts.last, 2)
        XCTAssertTrue(api.registered.isEmpty, "the host already holds this key")

        let first = try XCTUnwrap(store.pending.first { $0.id == "A-1042" })
        await store.decide(first, .approve, note: "ok")
        XCTAssertEqual(store.pendingCount, 1)
        XCTAssertEqual(badges.counts.last, 1)
        let sent = try XCTUnwrap(api.decided.first)
        XCTAssertEqual(sent.id, "A-1042")
        XCTAssertEqual(sent.body["decision"] as? String, "approve")
        XCTAssertEqual(sent.body["note"] as? String, "ok")
        XCTAssertNil(sent.body["input"])
        let exp = try XCTUnwrap(sent.body["exp"] as? Int)
        let message = JarvisApprovalSigner.canonicalMessage(id: "A-1042", type: first.type, subject: first.subject,
                                                            decisionWord: "approve", input: nil, exp: exp)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(sent.body["signature"] as? String)))
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: vectorSigner().publicKey).isValidSignature(signature, for: message))
    }

    func testAnActionNeedsItsInputAndSendsItTrimmed() async throws {
        var snapshot = try JarvisApprovals.snapshot(from: listing)
        snapshot.keyFingerprint = "65b6-0673-d6ed-884b"
        let api = FakeAPI(snapshot: snapshot)
        let store = makeStore(api, badges: BadgeLog())
        await store.refresh()
        let action = try XCTUnwrap(store.pending.first { $0.id == "A-1043" })
        await store.decide(action, .approve, input: "   ")
        XCTAssertTrue(api.decided.isEmpty)
        XCTAssertEqual(store.cardErrors["A-1043"]?.field, true)
        await store.decide(action, .approve, input: "  \(vectorInput)  ")
        XCTAssertEqual(api.decided.first?.body["input"] as? String, vectorInput)
        XCTAssertNil(store.cardErrors["A-1043"])
    }

    func testRetryOfAnActionSendsFreshInputSignedAsApprove() async throws {
        var snapshot = try JarvisApprovals.snapshot(from: listing)
        snapshot.keyFingerprint = "65b6-0673-d6ed-884b"
        let api = FakeAPI(snapshot: snapshot)
        let store = makeStore(api, badges: BadgeLog())
        await store.refresh()
        let row = try XCTUnwrap(store.pending.first { $0.id == "A-1043" })
        await store.decide(row, .retry, input: "  ")
        XCTAssertTrue(api.decided.isEmpty, "a retry that needs input will not go out empty")
        await store.decide(row, .retry, input: "  \(vectorInput) ")
        let body = try XCTUnwrap(api.decided.first?.body)
        XCTAssertEqual(body["decision"] as? String, "retry")
        XCTAssertEqual(body["input"] as? String, vectorInput)
        let exp = try XCTUnwrap(body["exp"] as? Int)
        let message = JarvisApprovalSigner.canonicalMessage(id: "A-1043", type: row.type, subject: row.subject,
                                                            decisionWord: "approve", input: vectorInput, exp: exp)
        let signature = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["signature"] as? String)))
        XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation: vectorSigner().publicKey).isValidSignature(signature, for: message))
    }

    func testARefusedKeyIsRegisteredAgain() async throws {
        var snapshot = try JarvisApprovals.snapshot(from: listing)
        snapshot.keyFingerprint = "65b6-0673-d6ed-884b"
        let api = FakeAPI(snapshot: snapshot)
        let store = makeStore(api, badges: BadgeLog())
        await store.refresh()
        api.refusal = JarvisApprovals.Refusal(status: 403, detail: "bad signature")
        await store.decide(try XCTUnwrap(store.pending.first), .approve)
        XCTAssertEqual(store.pendingCount, 2)
        XCTAssertEqual(store.cardErrors.values.first?.message, "This phone's key is not registered")
        XCTAssertEqual(api.registered.count, 1)
        XCTAssertEqual(api.registered.first?.key, "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ=")
    }

    // MARK: Countdown

    func testDeadlineChipText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func text(_ seconds: Double) -> String { JarvisApprovals.deadlineText(deadline: now.addingTimeInterval(seconds), now: now) }
        XCTAssertEqual(text(-5), "auto-deny due")
        XCTAssertEqual(text(20), "auto-deny in 1 min")
        XCTAssertEqual(text(45 * 60), "auto-deny in 45 min")
        XCTAssertEqual(text(5 * 3600 - 120), "auto-deny in 5 h")
        XCTAssertEqual(text(30 * 3600), "auto-deny in 30 h")
        XCTAssertEqual(text(4 * 86400), "auto-deny in 4 d")
    }

    func testCardShowsTypeAndSubjectAsSigned() {
        XCTAssertEqual(JarvisApprovalCard.signedLine(type: "a.b", subject: "x"), "a.b · x")
        XCTAssertEqual(JarvisApprovalCard.signedLine(type: "a.b", subject: ""), "a.b")
    }

    func testApprovalPushAndLinkAreRecognised() throws {
        XCTAssertTrue(JarvisApprovalsPush.isApproval(["aps": ["badge": 2], "jarvis": ["kind": "approval", "event": "badge", "id": ""]]))
        XCTAssertFalse(JarvisApprovalsPush.isApproval(["jarvis": ["kind": "other"]]))
        XCTAssertFalse(JarvisApprovalsPush.isApproval(["session_id": "x"]))
        let url = try XCTUnwrap(HermesDeepLink.approvalsURL)
        XCTAssertTrue(HermesDeepLink.isApprovalsURL(url))
        XCTAssertFalse(HermesDeepLink.isNewChatURL(url))
    }
}
