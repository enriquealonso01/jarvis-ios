import Foundation
import Security
import UIKit

/// Auth against the dashboard's RFC 8252 native flow:
///   1. POST {server}/auth/password-login  (provider "basic") — but that mints
///      browser cookies, so for the app we use the native branch:
///   2. GET  {server}/auth/native/authorize?provider=basic&code_challenge=…&code_challenge_method=S256&redirect_uri=http://127.0.0.1:8619/cb&state=…
///      → server 302s to /login with a broker PKCE cookie; we complete the
///      password form server-side via /auth/password-login (cookie jar),
///      then follow the loopback redirect carrying ?code=… and redeem it at
///      /auth/native/token for a Bearer access token.
///
/// Simplification used here (documented in docs/API.md): we do the whole
/// round trip with a transient in-process HTTP cookie jar (HTTPCookieStorage
/// on a private storage), then exchange code → tokens. The access token is
/// stored in the Keychain (never UserDefaults) and sent as
/// `Authorization: Bearer …` on every /api call. Refresh uses the stored
/// refresh token at /auth/native/refresh.
@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published private(set) var isAuthed: Bool
    @Published var lastError: String?

    private let accessKey = "jarvis.auth.access"
    private let refreshKey = "jarvis.auth.refresh"
    private let expiresKey = "jarvis.auth.expires"

    init() {
        isAuthed = Self.loadString(accessKey) != nil
    }

    var accessToken: String? { Self.loadString(accessKey) }
    var refreshToken: String? { Self.loadString(refreshKey) }
    var expiresAt: TimeInterval { TimeInterval(Self.loadString(expiresKey) ?? "0") ?? 0 }

    var isExpiringSoon: Bool {
        Date().timeIntervalSince1970 > expiresAt - 300
    }

    // MARK: Login

    /// Sign in with Enrique's dashboard credentials (provider: basic).
    func login(username: String, password: String) async {
        lastError = nil
        do {
            let cfg = ServerConfig.shared.config
            let base = cfg.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

            // 1. Native authorize (S256 PKCE, loopback redirect).
            // All URLs are built through serverURL() — never force-unwrapped:
            // `base` comes from Setup/Settings (user-typed), and a malformed
            // value must fail login with an error, not crash the app.
            let verifier = Self.randomURLSafe(length: 48)
            let challenge = Self.s256(verifier)
            let state = Self.randomURLSafe(length: 16)
            let redirect = "http://127.0.0.1:8619/cb"
            guard var comps = URLComponents(url: Self.serverURL(base, "/auth/native/authorize"),
                                            resolvingAgainstBaseURL: false) else {
                throw AuthError.badResponse("bad server URL")
            }
            comps.queryItems = [
                .init(name: "provider", value: "basic"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "state", value: state),
            ]
            guard let authorizeURL = comps.url else {
                throw AuthError.badResponse("bad server URL")
            }
            var req = URLRequest(url: authorizeURL)
            req.httpShouldHandleCookies = true
            let jar = HTTPCookieStorage()
            _ = try await Self.send(req, cookieJar: jar)   // 302 → /login, sets PKCE cookie

            // 2. Complete the password form (broker state rides the cookie).
            guard let loginURL = Self.serverURL(base, "/auth/password-login") else {
                throw AuthError.badResponse("bad server URL")
            }
            var loginReq = URLRequest(url: loginURL)
            loginReq.httpMethod = "POST"
            loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            loginReq.httpBody = try JSONEncoder().encode(
                PasswordLoginBody(provider: "basic", username: username, password: password)
            )
            let (data, resp) = try await Self.send(loginReq, cookieJar: jar)
            struct LoginResp: Decodable { let ok: Bool; let next: String }
            let login = try JSONDecoder().decode(LoginResp.self, from: data)
            guard login.ok, let next = URL(string: login.next),
                  let code = URLComponents(url: next, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value else {
                throw AuthError.badResponse("no loopback code")
            }

            // 3. Redeem code → bearer tokens.
            guard let tokenURL = Self.serverURL(base, "/auth/native/token") else {
                throw AuthError.badResponse("bad server URL")
            }
            var tokenReq = URLRequest(url: tokenURL)
            tokenReq.httpMethod = "POST"
            tokenReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            tokenReq.httpBody = try JSONEncoder().encode(NativeTokenBody(code: code, code_verifier: verifier))
            let (tokData, tokResp) = try await Self.send(tokenReq, cookieJar: nil)
            struct TokenResp: Decodable {
                let access_token: String
                let refresh_token: String
                let expires_at: Int
            }
            let tokens = try JSONDecoder().decode(TokenResp.self, from: tokData)
            Self.saveString(accessKey, tokens.access_token)
            Self.saveString(refreshKey, tokens.refresh_token)
            Self.saveString(expiresKey, String(tokens.expires_at))
            isAuthed = true
        } catch let err as AuthError {
            lastError = err.message
        } catch {
            lastError = "Login failed: \(error.localizedDescription)"
        }
    }

    /// Refresh via /auth/native/refresh; returns true when re-authed.
    @discardableResult
    func refresh() async -> Bool {
        guard let rt = refreshToken else { return false }
        let base = ServerConfig.shared.config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        // Never force-unwrap: refresh() runs from CCClient's auto-refresh on
        // any 401, so a malformed saved server URL must fail the refresh (→
        // login screen), not crash the app in the background.
        guard let url = Self.serverURL(base, "/auth/native/refresh") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(NativeRefreshBody(refresh_token: rt, provider: "basic"))
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct TokenResp: Decodable { let access_token: String; let refresh_token: String; let expires_at: Int }
            let tokens = try JSONDecoder().decode(TokenResp.self, from: data)
            Self.saveString(accessKey, tokens.access_token)
            Self.saveString(refreshKey, tokens.refresh_token)
            Self.saveString(expiresKey, String(tokens.expires_at))
            isAuthed = true
            return true
        } catch {
            return false
        }
    }

    func logout() {
        Self.deleteKey(accessKey)
        Self.deleteKey(refreshKey)
        Self.deleteKey(expiresKey)
        isAuthed = false
    }

    /// Access token guaranteed valid for the next few minutes: refreshes first
    /// when expiring soon. Used by the WebRTC client (backlog #4).
    func validAccessToken() async throws -> String {
        if accessToken == nil { throw AuthError.unauthorized }
        if isExpiringSoon, !await refresh() { throw AuthError.unauthorized }
        guard let token = accessToken else { throw AuthError.unauthorized }
        return token
    }

    /// Backlog #9: manual token entry from Settings (debug / minted-session
    /// fallback). Stores the token in the Keychain like the PKCE flow does.
    /// Expiry unknown — treat as expiring-soon so refresh attempts happen and
    /// a hard 401 just falls back to the login screen.
    func applyManualToken(_ token: String) {
        Self.saveString(accessKey, token)
        // keep prior refresh token if any; set expiry in the past-ish so the
        // client refreshes before first use rather than sending a stale token.
        if Self.loadString(expiresKey) == nil {
            Self.saveString(expiresKey, String(Date().timeIntervalSince1970 - 1))
        }
        lastError = nil
        isAuthed = true
    }

    enum AuthError: LocalizedError {
        case badResponse(String)
        case unauthorized
        var message: String {
            switch self {
            case .badResponse(let why): return "Unexpected server response (\(why))."
            case .unauthorized: return "Invalid username or password."
            }
        }
    }

    struct PasswordLoginBody: Encodable {
        let provider: String
        let username: String
        let password: String
        let next: String
        init(provider: String, username: String, password: String) {
            self.provider = provider
            self.username = username
            self.password = password
            self.next = ""
        }
    }
    struct NativeTokenBody: Encodable {
        let code: String
        let code_verifier: String
    }
    struct NativeRefreshBody: Encodable {
        let refresh_token: String
        let provider: String
    }

    // MARK: HTTP helpers

    /// Safely joins a (user-typed) server base with a path. Returns nil when
    /// the base is malformed — callers fail the request/login gracefully
    /// instead of force-unwrapping into a crash. Empty/absent scheme is
    /// repaired to https so "jarvis.enriquecodes.com" also works.
    static func serverURL(_ base: String, _ path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        // path starts with "/" by convention at every call site.
        return URL(string: trimmed + path)
    }

    /// URLSession.data with a one-off cookie jar (for the login round trip).
    static func send(_ req: URLRequest, cookieJar: HTTPCookieStorage?) async throws -> (Data, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        if let jar { config.httpCookieStorage = jar }
        let session = URLSession(configuration: config)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, !(400...599).contains(http.statusCode) else {
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 401 { throw AuthError.unauthorized }
            throw AuthError.badResponse("HTTP \(http?.statusCode ?? -1)")
        }
        return (data, resp)
    }

    static func randomURLSafe(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    static func s256(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    // MARK: Keychain

    static func saveString(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key] as CFDictionary)
        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil)
    }

    static func loadString(_ key: String) -> String? {
        var query = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary
        var out: AnyObject?
        guard SecItemCopyMatching(query, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteKey(_ key: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrAccount: key] as CFDictionary)
    }
}

import CryptoKit

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
