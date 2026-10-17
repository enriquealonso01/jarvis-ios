import Foundation

/// API client actor (plan §5.1). All network I/O lives here; Sendable struct
/// snapshots cross isolation boundaries. Stub for Item 0 — grows in Items 1–2.
public actor APIClient {
    private let config: ServerConfig
    private var token: String?
    private let session: URLSession

    public init(config: ServerConfig, token: String? = nil, session: URLSession = .shared) {
        self.config = config
        self.token = token
        self.session = session
    }

    public func setToken(_ newToken: String?) { token = newToken }

    /// GET an endpoint, returning decoded JSON. Never force-unwraps URLs.
    public func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = config.url(path) else { throw APIError.badURL(path) }
        var req = URLRequest(url: url)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public enum APIError: Error, Equatable, Sendable {
    case badURL(String)
    case badStatus(Int)
}
