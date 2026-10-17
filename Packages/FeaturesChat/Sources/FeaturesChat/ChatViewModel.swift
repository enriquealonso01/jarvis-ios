import Foundation

/// FeaturesChat stub (plan §5.1; features #1–#11 land here from M1 items 2–6).
/// Pure stream-state logic that Items 2+ will drive with real SSE events.
public struct StreamState: Sendable, Equatable {
    public var isStreaming: Bool
    public var committedText: String
    public var pendingText: String

    public init(isStreaming: Bool = false, committedText: String = "", pendingText: String = "") {
        self.isStreaming = isStreaming
        self.committedText = committedText
        self.pendingText = pendingText
    }

    public var displayText: String { committedText + pendingText }

    public mutating func begin() {
        isStreaming = true
        pendingText = ""
    }

    public mutating func append(token: String) {
        guard isStreaming else { return }
        pendingText += token
    }

    /// Commit coalesced pending text (main-actor commits at ~50–100ms cadence).
    public mutating func commitPending() {
        committedText += pendingText
        pendingText = ""
    }

    /// Stop cancels upstream WITHOUT losing committed text (UI Law §3).
    public mutating func stop() {
        commitPending()
        isStreaming = false
    }
}
