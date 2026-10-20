import CryptoKit
import Foundation
import Security

/// The Bearer the JARVIS push bridge (`/bridge/*`) and voice gateway (`/voice-gw/api/offer`)
/// verify: the dashboard's stateless native access token (`kind=access`, checked locally with
/// the dashboard secret). Hermex's password sign-in holds a cookie session instead, so the call
/// stack mints its own native token from the saved JARVIS sign-in, exactly as the v1 app did:
///
///   1. `POST /auth/password-login {provider: basic, username, password, code_challenge,
///      redirect_uri, state}`: the JARVIS cookie-less native fallback (the server re-registers
///      the pending authorization from the body) answers `{ok, next}`, `next` being the
///      loopback redirect carrying `?code=`. Nothing listens on the loopback: the code is read
///      from `next` itself.
///   2. `POST /auth/native/token {code, code_verifier}` answers `{access_token, refresh_token,
///      expires_at}`.
///   3. Later, `POST /auth/native/refresh {refresh_token, provider: basic}` rotates both.
///
/// Tokens live in the Keychain, readable after first unlock, so a PushKit wake on a locked phone
/// can still dial. The password is read from the saved sign-in only when there is no refresh
/// token or the host refused it.
@MainActor
final class JarvisVoiceAuth {
    static let shared = JarvisVoiceAuth()

    enum AuthError: LocalizedError {
        case notSignedIn
        case refused(Int)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to JARVIS first."
            case .refused(let status): return "JARVIS refused the voice sign-in (HTTP \(status))."
            case .badResponse(let why): return "Unexpected voice sign-in response (\(why))."
            }
        }
    }

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expiresAt: Double
    }

    private static let service = "com.enriquecodes.jarvis.voice-auth"
    private static let account = "native-bearer"
    private static let loopback = "http://127.0.0.1:8619/cb"
    private var inFlight: Task<String, Error>?

    var base: URL { JarvisServer.address }

    /// A token valid for at least the next five minutes. Concurrent callers share one attempt.
    func validAccessToken() async throws -> String {
        if let tokens = Self.load(), tokens.expiresAt - 300 > Date().timeIntervalSince1970 {
            return tokens.access
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { () throws -> String in
            if let tokens = Self.load(), let refreshed = try? await self.refresh(tokens.refresh) {
                return refreshed.access
            }
            return try await self.mint().access
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// The current token without any network, for best-effort requests.
    var cachedAccessToken: String? { Self.load()?.access }

    /// Forget the tokens, on sign-out.
    func reset() {
        SecItemDelete(Self.query as CFDictionary)
    }

    private func mint() async throws -> Tokens {
        guard let saved = try? BotConnectionStore().load(server: base), !saved.password.isEmpty else {
            throw AuthError.notSignedIn
        }
        let verifier = Self.randomURLSafe(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(16)
        let login = try await post("auth/password-login", [
            "provider": "basic", "username": saved.username, "password": saved.password, "next": "",
            "code_challenge": challenge, "redirect_uri": Self.loopback, "state": state
        ])
        guard login["ok"] as? Bool == true, let next = login["next"] as? String,
              let code = URLComponents(string: next)?.queryItems?.first(where: { $0.name == "code" })?.value
        else { throw AuthError.badResponse("no native code") }
        let tokens = try Self.tokens(from: try await post("auth/native/token", ["code": code, "code_verifier": verifier]))
        Self.save(tokens)
        return tokens
    }

    private func refresh(_ refreshToken: String) async throws -> Tokens {
        let tokens = try Self.tokens(from: try await post("auth/native/refresh",
                                                          ["refresh_token": refreshToken, "provider": "basic"]))
        Self.save(tokens)
        return tokens
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        // No cookie jar: the native fallback path takes the PKCE parameters from the body.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else { throw AuthError.refused(status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.badResponse("not JSON")
        }
        return object
    }

    private static func tokens(from json: [String: Any]) throws -> Tokens {
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let refresh = json["refresh_token"] as? String else { throw AuthError.badResponse("no tokens") }
        let expires = (json["expires_at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 + 3600
        return Tokens(access: access, refresh: refresh, expiresAt: expires)
    }

    // MARK: Keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func load() -> Tokens? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private static func save(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func randomURLSafe(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Where the call stack reaches JARVIS: the push bridge and the voice gateway, both behind the
/// JARVIS host's Caddy (`/bridge/*` strips its prefix; the gateway's offer is `/voice-gw/api/offer`).
enum JarvisCallEndpoints {
    static var bridge: URL { JarvisServer.address.appendingPathComponent("bridge") }
    static var voiceGateway: URL { JarvisServer.address }

    /// A JSON request to the bridge with the voice Bearer.
    @MainActor
    static func bridgeRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await JarvisVoiceAuth.shared.validAccessToken()
        var request = URLRequest(url: bridge.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200...299).contains(status) else {
            let detail = object["detail"] as? String
            throw JarvisVoiceAuth.AuthError.badResponse(detail ?? "bridge HTTP \(status)")
        }
        return object
    }
}
