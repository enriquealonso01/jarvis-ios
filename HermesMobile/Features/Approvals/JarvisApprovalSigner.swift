import CryptoKit
import Foundation
import Security

/// Signs the owner's answers. Every decision carries an Ed25519 signature made here, with a key
/// that is generated once, lives in the Keychain on this phone only (after first unlock, never
/// iCloud-synced, no biometric prompt) and never leaves it; the server holds the public half and
/// refuses an answer it did not sign.
///
/// The signature covers seven lines joined with `\n`, no trailing newline: `jarvis-approval-v1`,
/// the request's `id`, `type` and `subject` (empty when it has none), the decision word (`approve`
/// for an approval and a retry, `deny` for a denial), the lowercase hex SHA-256 of the trimmed
/// input text or `-` when there is none, and `exp` (epoch seconds) as a decimal integer.
struct JarvisApprovalSigner {
    static let messageVersion = "jarvis-approval-v1"

    private let key: Curve25519.Signing.PrivateKey

    init(privateKey: Curve25519.Signing.PrivateKey) {
        key = privateKey
    }

    /// This phone's signer: the Keychain's key, made on first use.
    static func onThisPhone() throws -> JarvisApprovalSigner {
        JarvisApprovalSigner(privateKey: try JarvisApprovalKeychain.loadOrCreate())
    }

    var publicKey: Data { key.publicKey.rawRepresentation }
    /// What `/bridge/approvals/register` takes as `signing_key`.
    var publicKeyBase64: String { publicKey.base64EncodedString() }
    var fingerprint: String { Self.fingerprint(of: publicKey) }

    /// The standard-base64 signature of one answer.
    func sign(id: String, type: String, subject: String, decision: JarvisApprovals.Decision, input: String?, exp: Int) throws -> String {
        let message = Self.canonicalMessage(id: id, type: type, subject: subject, decisionWord: decision.signedWord, input: input, exp: exp)
        return try key.signature(for: message).base64EncodedString()
    }

    // MARK: - Pieces

    static func canonicalMessage(id: String, type: String, subject: String, decisionWord: String, input: String?, exp: Int) -> Data {
        let lines = [messageVersion, id, type, subject, decisionWord, inputDigest(input), String(exp)]
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The lowercase hex SHA-256 of the trimmed input, or `-` for none.
    static func inputDigest(_ input: String?) -> String {
        guard let text = JarvisApprovals.firstText(input) else { return "-" }
        return hex(SHA256.hash(data: Data(text.utf8)))
    }

    /// The first 16 hex characters of the public key's SHA-256, as `xxxx-xxxx-xxxx-xxxx`.
    static func fingerprint(of publicKey: Data) -> String {
        let digits = Array(hex(SHA256.hash(data: publicKey)).prefix(16))
        return stride(from: 0, to: digits.count, by: 4).map { String(digits[$0..<min($0 + 4, digits.count)]) }.joined(separator: "-")
    }

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The signing key's one home: a generic-password Keychain item on this phone. A read that fails
/// for any reason but "not there" is an error, never a reason to make a second key.
enum JarvisApprovalKeychain {
    enum Failure: LocalizedError {
        case keychain(OSStatus)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .keychain(let status): return String(localized: "This phone's signing key can't be read (\(Int(status))).")
            case .unreadable: return String(localized: "This phone's signing key is damaged.")
            }
        }
    }

    private static let service = "com.enriquecodes.jarvis.approval-signing"
    private static let account = "ed25519-private-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(read as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
                throw Failure.unreadable
            }
            return key
        case errSecItemNotFound:
            let key = Curve25519.Signing.PrivateKey()
            var add = query
            add[kSecValueData as String] = key.rawRepresentation
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
            return key
        case let status:
            throw Failure.keychain(status)
        }
    }
}
