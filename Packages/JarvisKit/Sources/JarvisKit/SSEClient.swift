import Foundation

// MARK: - SSE wire-level event (transport layer, plan §5.3)
//
// One parsed SSE event per the W3C server-sent-events grammar: `id:` /
// `event:` / `data:` fields, comments, blank-line dispatch. Transport-level
// and framework-free so the deterministic fixtures (JarvisKit/Fixtures/*.sse)
// replay through the exact same parser the live connection uses.

public struct SSEEvent: Sendable, Equatable {
    /// Spec default when no `event:` field was seen.
    public static let defaultEventName = "message"

    public var id: String?
    public var event: String
    /// All `data:` lines of the event joined with "\n" (spec rule).
    public var data: String

    public init(id: String? = nil, event: String = SSEEvent.defaultEventName, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

/// Incremental SSE frame parser. Feed lines as they arrive (from
/// `URLSession.AsyncBytes.Lines`, a fixture file, or a test string); it emits
/// a complete `SSEEvent` on each blank line. Pure value type — no I/O.
public struct SSEParser: Sendable {
    private var dataLines: [String] = []
    private var pendingID: String?
    private var pendingEvent: String = SSEEvent.defaultEventName
    private var serverRetryMS: Int?

    public init() {}

    /// Server-suggested reconnect interval in ms (from a `retry:` field), if seen.
    public var retryMilliseconds: Int? { serverRetryMS }

    /// Feed one raw line (newline already stripped by the line source; a
    /// trailing CR from CRLF sources is tolerated). Returns events dispatched
    /// by this line (0 or 1).
    public mutating func feed(_ rawLine: String) -> [SSEEvent] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

        // Blank line: dispatch the accumulated event (if any) and reset.
        if line.isEmpty {
            return dispatch()
        }
        // Lines starting with ':' are comments / heartbeats — ignored.
        if line.hasPrefix(":") {
            return []
        }

        let (field, value) = splitField(line)
        switch field {
        case "data":
            dataLines.append(value)
        case "id":
            // Spec: an id containing NUL must be ignored.
            pendingID = value.contains("\u{0}") ? nil : value
        case "event":
            pendingEvent = value.isEmpty ? SSEEvent.defaultEventName : value
        case "retry":
            serverRetryMS = Int(value)
        default:
            break // unknown fields are ignored per spec
        }
        return []
    }

    /// Call at end-of-stream: dispatches a final unterminated event, if one
    /// was buffered without a trailing blank line.
    public mutating func flush() -> [SSEEvent] {
        dispatch()
    }

    private mutating func dispatch() -> [SSEEvent] {
        defer {
            dataLines = []
            pendingID = nil
            pendingEvent = SSEEvent.defaultEventName
        }
        // Spec: an event with no data lines is not dispatched.
        guard !dataLines.isEmpty else { return [] }
        return [SSEEvent(id: pendingID, event: pendingEvent, data: dataLines.joined(separator: "\n"))]
    }

    /// "field: value" → ("field", "value") — strips exactly one leading space
    /// from the value. "field:value" → ("field", "value"). No colon → the
    /// whole line is the field with an empty value.
    private func splitField(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        return (String(line[..<colon]), value)
    }
}

// MARK: - Errors / options

public enum SSEError: Error, Equatable, Sendable {
    case badURL(String)
    case badResponse
    case badStatus(Int)
}

public struct SSEOptions: Sendable {
    /// Give up the connection when no bytes (lines OR comments) arrive for
    /// this long — heartbeat/dead-connection detection.
    public var heartbeatTimeout: Double
    /// First reconnect delay (seconds); doubles each consecutive failure.
    public var baseBackoff: Double
    /// Backoff cap (plan §5.3: ~60s) with ±jitterFraction jitter.
    public var maxBackoff: Double
    public var jitterFraction: Double
    /// Give up after this many consecutive failed attempts (nil = unlimited).
    /// Reset whenever the connection delivered any data.
    public var maxAttempts: Int?

    public init(heartbeatTimeout: Double = 30,
                baseBackoff: Double = 1,
                maxBackoff: Double = 60,
                jitterFraction: Double = 0.25,
                maxAttempts: Int? = nil) {
        self.heartbeatTimeout = heartbeatTimeout
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.jitterFraction = jitterFraction
        self.maxAttempts = maxAttempts
    }
}

// MARK: - SSEClient

/// GET-based SSE transport (plan §5.3, feature #1). One live stream per
/// client instance: `events(conversationID:lastEventID:)` returns an
/// `AsyncThrowingStream<AgentEvent>` fed by a `URLSession.bytes` connection.
///
/// - Resume: sends `Last-Event-ID: <seq>` on reconnect so the server
///   continues after the last delivered event (monotonic ids).
/// - Reconnect: exponential backoff `base * 2^n` capped at `maxBackoff` with
///   ±jitter; the counter resets after any data was received. A server
///   `retry:` field overrides the computed delay (still capped).
/// - Heartbeat: a watchdog cancels and reopens the connection when no lines
///   (data or `: keepalive` comments) arrive within `heartbeatTimeout`.
/// - Terminal errors (`4xx` except 429, bad URL/response) finish the stream
///   with the error instead of retrying.
/// - `close()` cancels upstream gracefully: the stream finishes (no error).
///
/// The connection read loop runs on a detached task and hands each line to
/// the actor (`ingest(line:)`), so all parser/seq state stays actor-isolated.
public actor SSEClient {
    private let config: ServerConfig
    private let session: URLSession
    private let options: SSEOptions

    private var closed = false
    private var seq: Int64 = 0
    private var attemptEpoch = 0
    private var pumpTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastActivityAt: Date = .distantPast
    private var gotDataThisAttempt = false
    private var serverRetryMS: Int?
    private var connectionError: Error?
    private var parser = SSEParser()
    private var active: AsyncThrowingStream<AgentEvent, Error>.Continuation?

    public init(config: ServerConfig, session: URLSession = .shared, options: SSEOptions = SSEOptions()) {
        self.config = config
        self.session = session
        self.options = options
    }

    /// GET stream endpoint for a conversation (fixture contract, see
    /// JarvisKit/Fixtures/contract.json).
    public nonisolated static func streamEndpoint(_ conversationID: UUID) -> String {
        "/v1/conversations/\(conversationID.uuidString)/events"
    }

    // MARK: Pure helpers (unit-tested, no I/O)

    /// Exponential backoff with jitter: `base * 2^attempt` capped at
    /// `maxDelay`, offset by ±`jitterFraction` of the capped delay.
    /// `jitter` ∈ [0, 1] is injectable for deterministic tests.
    public nonisolated static func backoffDelay(attempt: Int,
                                                jitter: Double,
                                                base: Double = 1,
                                                maxDelay: Double = 60,
                                                jitterFraction: Double = 0.25) -> Double {
        let capped = min(base * pow(2.0, Double(max(0, attempt))), maxDelay)
        let spread = capped * jitterFraction
        return max(0, capped + (jitter * 2.0 - 1.0) * spread)
    }

    /// Terminal = retrying can never help (auth, not found, malformed URL).
    public nonisolated static func isTerminal(_ error: Error) -> Bool {
        switch error {
        case SSEError.badURL, SSEError.badResponse:
            return true
        case SSEError.badStatus(let code):
            return (400..<500).contains(code) && code != 429
        default:
            return false
        }
    }

    /// Map a transport-level `SSEEvent` to the app-level `AgentEvent`.
    ///
    /// Two envelope forms share the stream (see Fixtures/contract.json):
    /// - **Native**: `event:` carries the kind, `id:` the seq, `data:` is the
    ///   raw payload (token text or a JSON object stringified).
    /// - **Legacy JSON envelope**: no `event:` field (or `message`); `data:`
    ///   is `{"id": N, "kind": "...", "payload": "..."}`.
    public nonisolated static func agentEvent(from sse: SSEEvent) -> AgentEvent? {
        guard !sse.data.isEmpty else { return nil }
        if sse.event != SSEEvent.defaultEventName {
            return AgentEvent(id: Int64(sse.id ?? "") ?? 0, kind: sse.event, payload: sse.data)
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(sse.data.utf8))) as? [String: Any],
              let kind = obj["kind"] as? String else { return nil }
        let id = Int64(sse.id ?? "") ?? (obj["id"] as? NSNumber)?.int64Value ?? 0
        let payload = (obj["payload"] as? String) ?? sse.data
        return AgentEvent(id: id, kind: kind, payload: payload)
    }

    /// Legacy single-line helper (pinned by Item 0 smoke tests): parse one
    /// `data: {...}` JSON-envelope line directly.
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

    // MARK: Public stream surface

    /// Open (or reopen) the conversation's event stream. Any previously
    /// active stream on this client is superseded gracefully. `lastEventID`
    /// seeds the resume pointer: the first (re)connection sends
    /// `Last-Event-ID: <seq>` so the server skips already-delivered events.
    public func events(conversationID: UUID, lastEventID: Int64? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
        // Supersede any previous stream.
        pumpTask?.cancel()
        connectionTask?.cancel()
        watchdogTask?.cancel()
        active?.finish()

        closed = false
        seq = lastEventID ?? 0

        var box: AsyncThrowingStream<AgentEvent, Error>.Continuation?
        let stream = AsyncThrowingStream<AgentEvent, Error> { box = $0 }
        guard let continuation = box else { return stream }
        active = continuation

        let task = Task { await self.pump(conversationID: conversationID, into: continuation) }
        pumpTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Graceful close: cancel upstream and finish the stream without error.
    /// Committed content is untouched (UI Law §3 — stop never loses text).
    public func close() {
        closed = true
        pumpTask?.cancel()
        pumpTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        active?.finish()
        active = nil
    }

    /// Highest event seq delivered so far (persist as the resume pointer).
    public func lastEventID() -> Int64 { seq }

    // MARK: Internals (actor-isolated)

    /// Reconnect loop: connect → read until the connection ends → classify →
    /// backoff → repeat. Finishes the stream on `close()`, consumer
    /// termination, terminal errors, or retry-budget exhaustion.
    private func pump(conversationID: UUID,
                      into continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        var consecutiveFailures = 0
        while !Task.isCancelled && !closed {
            gotDataThisAttempt = false
            serverRetryMS = nil
            do {
                try await connectOnce(conversationID: conversationID)
            } catch {
                connectionError = nil
                if closed || Task.isCancelled { break }
                if Self.isTerminal(error) {
                    active = nil
                    continuation.finish(throwing: error)
                    return
                }
                if let cap = options.maxAttempts, consecutiveFailures + 1 >= cap {
                    active = nil
                    continuation.finish(throwing: error)
                    return
                }
                consecutiveFailures += 1
            }
            if closed || Task.isCancelled { break }
            // Any delivered data proves the path works — reset the budget.
            if gotDataThisAttempt { consecutiveFailures = 0 }

            let delay: Double
            if let ms = serverRetryMS {
                delay = min(Double(ms) / 1000.0, options.maxBackoff)
            } else {
                delay = Self.backoffDelay(attempt: consecutiveFailures,
                                          jitter: Double.random(in: 0...1),
                                          base: options.baseBackoff,
                                          maxDelay: options.maxBackoff,
                                          jitterFraction: options.jitterFraction)
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
        }
        active = nil
        continuation.finish()
    }

    /// One connection attempt. Throws the failure reason when the connection
    /// ends abnormally; returns normally on clean EOF or `close()`.
    private func connectOnce(conversationID: UUID) async throws {
        guard let url = config.url(Self.streamEndpoint(conversationID)) else {
            throw SSEError.badURL(Self.streamEndpoint(conversationID))
        }
        let resumeHeader: String? = seq > 0 ? String(seq) : nil
        parser = SSEParser()
        lastActivityAt = Date()
        attemptEpoch += 1
        let epoch = attemptEpoch
        let session = self.session
        let heartbeat = options.heartbeatTimeout

        let conn = Task<Void, Never> { [weak self] in
            guard let self else { return }
            var request = URLRequest(url: url)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 300
            if let resumeHeader {
                request.setValue(resumeHeader, forHTTPHeaderField: "Last-Event-ID")
            }
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await self.finishConnection(SSEError.badResponse)
                    return
                }
                guard http.statusCode == 200 else {
                    await self.finishConnection(SSEError.badStatus(http.statusCode))
                    return
                }
                for try await line in bytes.lines {
                    await self.ingest(line: line)
                }
                await self.finishConnection(nil) // clean EOF
            } catch {
                await self.finishConnection(error)
            }
        }
        connectionTask = conn
        startWatchdog(epoch: epoch, timeout: heartbeat)
        _ = await conn.value
        watchdogTask?.cancel()
        watchdogTask = nil
        connectionTask = nil
        if let error = connectionError {
            connectionError = nil
            throw error
        }
    }

    /// Watchdog: while the connection `epoch` is current, cancel it if no
    /// line arrived within `timeout` (dead TCP / stalled proxy detection).
    private func startWatchdog(epoch: Int, timeout: Double) {
        watchdogTask?.cancel()
        let interval = max(timeout / 2, 0.05)
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                if await self.heartbeatExpired(epoch: epoch, timeout: timeout) { return }
            }
        }
    }

    private func heartbeatExpired(epoch: Int, timeout: Double) -> Bool {
        guard !closed, epoch == attemptEpoch else { return false }
        if Date().timeIntervalSince(lastActivityAt) >= timeout {
            connectionTask?.cancel()
            return true
        }
        return false
    }

    /// Called on the actor for every received line (data OR comment) — any
    /// line counts as liveness for the heartbeat detector.
    private func ingest(line: String) {
        lastActivityAt = Date()
        gotDataThisAttempt = true
        if let ms = parser.retryMilliseconds { serverRetryMS = ms }
        for event in parser.feed(line) {
            emit(event)
        }
    }

    /// EOF flush: a buffered event without a trailing blank line still ships.
    private func finishConnection(_ error: Error?) {
        for event in parser.flush() {
            emit(event)
        }
        connectionError = error
    }

    private func emit(_ sse: SSEEvent) {
        guard let agent = Self.agentEvent(from: sse) else { return }
        if agent.id > seq { seq = agent.id }
        _ = active?.yield(agent)
    }
}
