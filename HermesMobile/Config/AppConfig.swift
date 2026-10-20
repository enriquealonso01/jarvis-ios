import Foundation

enum AppConfig {
    /// Hermex, the MIT-licensed SwiftUI client JARVIS v3 is a fork of.
    static let hermexURL = URL(staticString: "https://github.com/uzairansaruzi/hermex")
}

extension URL {
    init(staticString string: StaticString) {
        let value = string.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid static URL literal: \(value)")
        }
        self = url
    }
}
