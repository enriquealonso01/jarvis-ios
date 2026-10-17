import Foundation

/// JarvisIntents stub (App Intents package, plan §5.1). Real
/// AppShortcutsProvider + ControlWidget intents land in M4. Deep-link routing
/// kept as a pure enum so it's unit-testable today (widget taps use jarvis://
/// per the existing v1 scheme).
public enum DeepLink: Sendable, Equatable {
    case chat(conversationID: UUID)
    case run(runID: UUID)
    case startCall
    case unknown

    public static func parse(_ url: URL) -> DeepLink {
        guard url.scheme == "jarvis" else { return .unknown }
        switch url.host {
        case "call":
            return .startCall
        case "chat":
            if let id = UUID(uuidString: url.lastPathComponent) { return .chat(conversationID: id) }
            return .unknown
        case "run":
            if let id = UUID(uuidString: url.lastPathComponent) { return .run(runID: id) }
            return .unknown
        default:
            return .unknown
        }
    }
}
