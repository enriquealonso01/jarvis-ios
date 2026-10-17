import Foundation

/// Transport-agnostic send closure the outbox drain calls per entry.
/// Returns successfully when the backend accepted the entry.
public typealias OutboxSend = @Sendable (_ entry: OutboxEntry) async throws -> Void

/// Outbox drain actor (plan §5.2 / feature #4): replays unsent sends with
/// exponential backoff 2^n capped at ~60s with jitter, reset on success.
///
/// The transport is injected (`OutboxSend` closure), so the drain/backoff
/// logic is unit-testable without any network.
public actor OutboxActor {
    /// Backoff base: delay = 2^attempt seconds, capped.
    static let maxBackoffSeconds: Double = 60.0
    /// Jitter fraction: ±25% of the computed delay.
    static let jitterFraction: Double = 0.25

    private let store: PersistenceStore
    private let send: OutboxSend
    /// Randomness source for jitter (safe: this actor serializes access).
    private var rng = SystemRandomNumberGenerator()

    public init(store: PersistenceStore, send: @escaping OutboxSend) {
        self.store = store
        self.send = send
    }

    /// Backoff for a failed attempt `n` (0-based): 2^n seconds capped at 60s
    /// with ±25% jitter. Exposed (static, pure) for unit tests.
    public static func backoffSeconds(afterAttempt attempt: Int,
                                      jitter: Double = 0.5) -> Double {
        let base = min(pow(2.0, Double(attempt + 1)), maxBackoffSeconds)
        let spread = base * jitterFraction
        // Map jitter ∈ [0,1] to [-spread, +spread].
        let offset = (jitter * 2.0 - 1.0) * spread
        return max(0, base + offset)
    }

    /// Drain due entries once. Returns the number of successfully sent
    /// entries. Failed entries stay queued with backoff-advanced
    /// `nextAttemptAt`. `now` injectable for deterministic tests.
    @discardableResult
    public func drainOnce(now: Double? = nil) async throws -> Int {
        let currentNow = now ?? Date().timeIntervalSince1970
        let due = try await store.dueOutboxEntries(now: currentNow)
        var sent = 0
        for entry in due {
            do {
                try await send(entry)
                try await store.removeOutboxEntry(id: entry.id)
                sent += 1
            } catch {
                let jitter = Double.random(in: 0...1)
                let delay = Self.backoffSeconds(afterAttempt: entry.attempt, jitter: jitter)
                try await store.recordOutboxFailure(id: entry.id, nextAttemptAt: currentNow + delay)
            }
        }
        return sent
    }

    /// Drain until the queue is empty of due entries, with real waiting on
    /// backoff between rounds (bounded by `maxAttempts`). Reset-on-success is
    /// implicit: sent entries leave the queue.
    public func drainUntilEmpty(maxRounds: Int = 20,
                                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) async throws -> Int {
        var total = 0
        for _ in 0..<maxRounds {
            let sent = try await drainOnce(now: now())
            total += sent
            let remaining = try await store.dueOutboxEntries(now: now())
            if remaining.isEmpty { break }
            // Wait until the earliest next attempt (bounded by cap).
            let wait = min(remaining.map(\.nextAttemptAt).max() ?? 0, now() + Self.maxBackoffSeconds) - now()
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
        return total
    }

    /// Called on reconnect: retry everything immediately (clears backoff
    /// timers by pulling `nextAttemptAt` to now), then drain once.
    @discardableResult
    public func drainOnReconnect(now: Double? = nil) async throws -> Int {
        let currentNow = now ?? Date().timeIntervalSince1970
        try await store.resetOutboxBackoff(now: currentNow)
        return try await drainOnce(now: currentNow)
    }
}
