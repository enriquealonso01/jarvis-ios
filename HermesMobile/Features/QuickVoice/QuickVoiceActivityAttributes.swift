import ActivityKit
import Foundation

/// Quick Voice's Live Activity attributes: the recording pill shown on the Lock
/// Screen and in the Dynamic Island while the Action button's recording runs
/// (JARVIS Quick Voice). Minimal by design — the pill is a red dot, a line, and a
/// system-drawn timer; the session tap target only exists once the send succeeded.
struct QuickVoiceActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case recording
        case sending
        case done
        case failed
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var startedAt: Date
        /// One short line under the timer ("JARVIS listening…", "Sending…", why it failed).
        var message: String
        /// `hermes-agent://session?…` once the send succeeded, so a tap opens the chat.
        var destinationURL: URL?
        var schemaVersion = 1

        enum CodingKeys: String, CodingKey {
            case phase, startedAt, message, destinationURL, schemaVersion = "v"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .recording
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
            destinationURL = try c.decodeIfPresent(URL.self, forKey: .destinationURL)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }

        /// Explicit memberwise init: the Codable init above suppresses the
        /// compiler-synthesized one, and the controller builds states in memory.
        init(phase: Phase, startedAt: Date, message: String, destinationURL: URL? = nil) {
            self.phase = phase
            self.startedAt = startedAt
            self.message = message
            self.destinationURL = destinationURL
        }
    }

    init() {}
}
