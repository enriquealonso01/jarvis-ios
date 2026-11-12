import Foundation

/// One request an agent filed for the owner's decision, as `/bridge/approvals` lists it. Decoded
/// tolerantly (`BotJSON`): a missing field is a nil or a default, and only an `id` is required.
struct JarvisApproval: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case decision, action }

    struct Link: Equatable, Hashable, Sendable {
        let label: String
        let url: URL
    }

    /// The box an `action` asks the owner to fill.
    struct Input: Equatable, Sendable {
        let label: String
        let placeholder: String
        let required: Bool
        let mismatch: String?
    }

    /// The agent session that filed the request, to open its chat.
    struct Session: Equatable, Sendable {
        let id: String
        let profile: String?
        let source: String?
    }

    let id: String
    let project: String
    let projectName: String
    /// The action's name and its target: what the owner's signature covers.
    let type: String
    let subject: String
    let adhoc: Bool
    let kind: Kind
    let title: String
    let evidence: String?
    /// The agent wrote the evidence itself, so it is not the system's word.
    let evidenceFromAgent: Bool
    let links: [Link]
    let input: Input?
    let createdAt: Date?
    let deadline: Date?
    /// `pending`, `running`, `failed`, `approved`, `denied`, `expired`, `closed`, or one a newer
    /// server added.
    let state: String
    let decidedAt: Date?
    let decidedVia: String?
    let note: String?
    let result: String?
    let outcome: String?
    let canRetry: Bool
    let session: Session?
    let runsAction: Bool

    var isPending: Bool { state == "pending" }
    /// The project's heading: its name, else its key.
    var heading: String { JarvisApprovals.firstText(projectName, project) ?? "" }
    /// What the Recent row says happened: the outcome, else the action's result.
    var summary: String? { JarvisApprovals.firstText(outcome, result) }

    init?(json row: BotJSON) {
        guard let id = JarvisApprovals.firstText(row["id"].text) else { return nil }
        self.id = id
        project = row["project"].text ?? ""
        projectName = row["project_name"].text ?? ""
        type = row["type"].text ?? ""
        subject = row["subject"].text ?? ""
        adhoc = row["adhoc"].flag ?? false
        kind = row["kind"].text == "action" ? .action : .decision
        title = JarvisApprovals.firstText(row["title"].text, row["subject"].text) ?? id
        evidence = JarvisApprovals.firstText(row["evidence"].text)
        evidenceFromAgent = row["evidence_source"].text == "agent"
        links = (row["links"].list ?? []).compactMap { link -> Link? in
            guard let raw = link["url"].text, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return Link(label: JarvisApprovals.firstText(link["label"].text) ?? url.host ?? raw, url: url)
        }
        if row["input"].fields != nil {
            let box = row["input"]
            input = Input(label: box["label"].text ?? "", placeholder: box["placeholder"].text ?? "",
                          required: box["required"].flag ?? true, mismatch: JarvisApprovals.firstText(box["mismatch"].text))
        } else {
            input = nil
        }
        createdAt = row["created_at"].number.map(Date.init(timeIntervalSince1970:))
        deadline = row["deadline_at"].number.map(Date.init(timeIntervalSince1970:))
        state = row["state"].text ?? "pending"
        decidedAt = row["decided_at"].number.map(Date.init(timeIntervalSince1970:))
        decidedVia = row["decided_via"].text
        note = JarvisApprovals.firstText(row["note"].text)
        result = JarvisApprovals.firstText(row["result"].text)
        outcome = JarvisApprovals.firstText(row["outcome"].text)
        canRetry = row["can_retry"].flag ?? false
        if let sessionID = JarvisApprovals.firstText(row["session"]["id"].text) {
            session = Session(id: sessionID, profile: row["session"]["profile"].text, source: row["session"]["source"].text)
        } else {
            session = nil
        }
        runsAction = row["runs_action"].flag ?? false
    }
}

/// Approvals: JARVIS's agents file a request, the owner answers it in the app with a signature
/// made on the phone (`JarvisApprovalSigner`), the server runs the action and wakes the agent.
/// This is the model and the bridge calls (`/bridge/approvals`, app Bearer like `/bridge/route`).
enum JarvisApprovals {
    /// The owner's answer. `retry` goes out as its own word but is signed as an approval.
    enum Decision: String, Sendable {
        case approve, deny, retry

        /// The word the signature covers.
        var signedWord: String { self == .deny ? "deny" : "approve" }
    }

    /// A signature is good for ten minutes.
    static let signatureLifetime = 600
    static let noteLimit = 240

    /// One answer from `/bridge/approvals`.
    struct Snapshot: Equatable, Sendable {
        var now: Date?
        var keyFingerprint: String?
        var alertRegistered: Bool
        var pending: [JarvisApproval]
        var recent: [JarvisApproval]
    }

    /// An approval project's heading and its cards.
    struct Group: Identifiable, Equatable {
        let name: String
        let items: [JarvisApproval]
        var id: String { name }
    }

    /// The bridge refused: its HTTP status and the sentence it gave (`detail`).
    struct Refusal: LocalizedError, Equatable {
        let status: Int
        let detail: String?

        var errorDescription: String? {
            detail ?? String(localized: "JARVIS couldn't be reached. Check your connection and try again.")
        }
    }

    // MARK: - Decoding

    static func snapshot(from body: Data) throws -> Snapshot {
        let json = try JSONDecoder().decode(BotJSON.self, from: body)
        guard json.fields != nil else { throw APIError.decoding(underlying: BotFailure.unsupported) }
        return Snapshot(
            now: json["now"].number.map(Date.init(timeIntervalSince1970:)),
            keyFingerprint: firstText(json["key_fingerprint"].text),
            alertRegistered: json["alert_registered"].flag ?? false,
            pending: (json["pending"].list ?? []).compactMap { JarvisApproval(json: $0) },
            recent: (json["recent"].list ?? []).compactMap { JarvisApproval(json: $0) }
        )
    }

    /// The `item` of a `/decision` answer.
    static func item(from body: Data) -> JarvisApproval? {
        (try? JSONDecoder().decode(BotJSON.self, from: body)).flatMap { JarvisApproval(json: $0["item"]) }
    }

    // MARK: - Ordering

    /// Cards by project (A to Z); in a project, the nearest deadline first, then the oldest.
    static func groups(_ items: [JarvisApproval]) -> [Group] {
        Dictionary(grouping: items, by: { $0.heading.isEmpty ? String(localized: "Other") : $0.heading })
            .map { Group(name: $0.key, items: $0.value.sorted(by: urgency)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func urgency(_ a: JarvisApproval, _ b: JarvisApproval) -> Bool {
        if a.deadline != b.deadline {
            guard let left = a.deadline else { return false }
            guard let right = b.deadline else { return true }
            return left < right
        }
        if a.createdAt != b.createdAt {
            guard let left = a.createdAt else { return false }
            guard let right = b.createdAt else { return true }
            return left < right
        }
        return a.id < b.id
    }

    /// Most recently answered first.
    static func recentOrder(_ items: [JarvisApproval]) -> [JarvisApproval] {
        items.sorted { a, b in
            let left = a.decidedAt ?? a.createdAt ?? .distantPast, right = b.decidedAt ?? b.createdAt ?? .distantPast
            return left == right ? a.id < b.id : left > right
        }
    }

    // MARK: - Text

    /// "auto-deny in 5 h": the time left to a deadline, in the nearest unit.
    static func deadlineText(deadline: Date, now: Date) -> String {
        let seconds = deadline.timeIntervalSince(now)
        if seconds <= 0 { return String(localized: "auto-deny due") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return String(localized: "auto-deny in \(minutes) min") }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return String(localized: "auto-deny in \(hours) h") }
        let days = Int((seconds / 86400).rounded())
        return String(localized: "auto-deny in \(days) d")
    }

    /// What a state reads as on a Recent row.
    static func stateText(_ state: String) -> String {
        switch state {
        case "approved": return String(localized: "Approved")
        case "denied": return String(localized: "Denied")
        case "expired": return String(localized: "Expired")
        case "failed": return String(localized: "Failed")
        case "running": return String(localized: "Running")
        case "closed": return String(localized: "Closed")
        case "pending": return String(localized: "Pending")
        default: return state.capitalized
        }
    }

    /// The first of `texts` that is not blank, trimmed.
    static func firstText(_ texts: String?...) -> String? {
        for text in texts {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Requests

    /// `POST /bridge/approvals/{id}/decision`'s body: the signature, its expiry, and the trimmed
    /// input (an action's box) and note when there are any.
    static func decisionBody(decision: Decision, signature: String, exp: Int, input: String?, note: String?) -> [String: Any] {
        var body: [String: Any] = ["decision": decision.rawValue, "signature": signature, "exp": exp]
        if let input = firstText(input) { body["input"] = input }
        if let note = firstText(note) { body["note"] = String(note.prefix(noteLimit)) }
        return body
    }

    /// `POST /bridge/approvals/register`'s body: the push token and the public signing key, either
    /// or both.
    static func registerBody(alertToken: String?, signingKey: String?) -> [String: Any] {
        var body: [String: Any] = [:]
        if let alertToken { body["alert_token"] = alertToken }
        if let signingKey { body["signing_key"] = signingKey }
        return body
    }
}

/// The bridge calls the store makes, so tests can stand in for them.
@MainActor
protocol JarvisApprovalsAPI {
    func list() async throws -> JarvisApprovals.Snapshot
    func decide(id: String, body: [String: Any]) async throws -> JarvisApproval?
    func register(alertToken: String?, signingKey: String?) async throws
}

/// `/bridge/approvals` through `JarvisCallEndpoints.bridgeExchange`.
@MainActor
struct JarvisApprovalsBridge: JarvisApprovalsAPI {
    func list() async throws -> JarvisApprovals.Snapshot {
        try JarvisApprovals.snapshot(from: try await send("approvals"))
    }

    func decide(id: String, body: [String: Any]) async throws -> JarvisApproval? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return JarvisApprovals.item(from: try await send("approvals/\(encoded)/decision", method: "POST", body: body))
    }

    func register(alertToken: String?, signingKey: String?) async throws {
        _ = try await send("approvals/register", method: "POST",
                           body: JarvisApprovals.registerBody(alertToken: alertToken, signingKey: signingKey))
    }

    /// The answer's JSON, or the bridge's refusal with its sentence.
    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let (status, object) = try await JarvisCallEndpoints.bridgeExchange(path, method: method, body: body)
        guard (200...299).contains(status) else {
            throw JarvisApprovals.Refusal(status: status, detail: JarvisApprovals.firstText(object["detail"] as? String))
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
