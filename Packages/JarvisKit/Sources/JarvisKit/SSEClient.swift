import Foundation

/// SSE client stub (plan §5.3). Real implementation (URLSession.bytes +
/// `for try await line in bytes.lines`) lands in Item 2 with the ingest actor.
/// The event parse below is the part that is real and unit-tested now.
public actor SSEClient {
    public init() {}

    /// Parse one `data:` SSE chunk into an AgentEvent. Pure logic, shared with
    /// the future bytes-based transport and the deterministic fixtures.
    public nonisolated static func parseEvent(_ line: String) -> AgentEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else { return nil }
        let id = (obj["id"] as? NSNumber)?.int64Value ?? 0
        let payload = (obj["payload"] as? String) ?? ""
        return AgentEvent(id: id, kind: kind, payload: payload)
    }
}
