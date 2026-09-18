import Foundation
import PushKit
import CallKit
import AVFoundation
import UIKit

/// Backlog #4: PushKit VoIP provider + CallKit call controller.
///
/// Lifecycle:
///  1. App launch -> `CredentialProviderFixture`/registration: `reportNewIncomingVoIPPush`
///     is only called when a push arrives; PushKit registration happens in `pushRegistry(_:didUpdate:)`.
///  2. Bridge fires a VoIP push with payload {reason, call_id, gateway_ws, scheduled_by}.
///  3. We MUST report the incoming call to CallKit before exiting this callback
///     (iOS kills the app otherwise), then connect WebRTC asynchronously.
@MainActor
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published var lastPayload: VoIPPayload?
    @Published var activeCallUUID: UUID?
    @Published var callState: String = "idle"

    private var callController: CXCallController?
    private var provider: CXProvider?
    private var webRTC: WebRTCClient?
    /// lastPayload of the call currently being answered (read before WebRTC connect)
    private(set) var pendingAnswerPayload: VoIPPayload?

    struct VoIPPayload {
        let reason: String
        let callID: String
        let gatewayWS: String
        let scheduledBy: String?
    }

    override private init() {
        super.init()
    }

    // MARK: PushKit registration

    func registerVoIP() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }
    private var voipRegistry: PKPushRegistry?

    // MARK: Incoming push (called from AppDelegate)

    func handleVoIPPayload(_ payload: [AnyHashable: Any]) {
        let p = VoIPPayload(
            reason: payload["reason"] as? String ?? "JARVIS call",
            callID: payload["call_id"] as? String ?? UUID().uuidString.prefix(8).description,
            gatewayWS: payload["gateway_ws"] as? String ?? "/voice-gw",
            scheduledBy: payload["scheduled_by"] as? String
        )
        lastPayload = p
        pendingAnswerPayload = p

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "JARVIS")
        update.hasVideo = false
        update.localizedCallerName = "JARVIS"

        let uuid = UUID()
        activeCallUUID = uuid
        let config = CXProviderConfiguration(localizedName: "JARVIS")
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        let prov = CXProvider(configuration: config)
        prov.delegate = self
        provider = prov
        callController = CXCallController()
        callState = "ringing"
        // Report BEFORE returning from the VoIP push callback (hard requirement).
        prov.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error { print("[CallManager] report incoming failed: \(error)") }
        }
    }

    // MARK: Answer / end (driven by CXProviderDelegate)

    private func connectWebRTC() async throws {
        guard let payload = pendingAnswerPayload else { return }
        callState = "connecting"
        let base = ServerConfig.shared.config.voiceGWURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let offerURL = base + payload.gatewayWS + "/api/offer"
        let client = try await WebRTCClient.connect(offerURL: offerURL,
                                                    tokenProvider: { @Sendable in try await AuthStore.shared.validAccessToken() })
        webRTC = client
        callState = "active"
        Haptics.success()
    }

    func endActiveCall() {
        if let uuid = activeCallUUID { provider?.reportCall(with: uuid, endedAt: Date()) }
        webRTC?.hangup()
        webRTC = nil
        activeCallUUID = nil
        callState = "idle"
    }
}

// MARK: - PushKit

extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        Task { await self.sendDeviceToken(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        Task { @MainActor in
            self.handleVoIPPayload(payload.dictionaryPayload)
            completion()
        }
    }

    @MainActor
    private func sendDeviceToken(_ token: String) async {
        // /register requires the agent HMAC; the app cannot compute it, but the
        // endpoint also accepts nothing else — so we proxy through the bridge's
        // Bearer-authed path once available. For now fire-and-forget against
        // /register using the Bearer (bridge accepts dual auth after this commit).
        let cfg = ServerConfig.shared.config
        let url = URL(string: cfg.bridgeBaseURL + "/register")
        guard let url else { return }
        var req = URLRequest(postTo: url)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_token": token, "bundle_id": Bundle.main.bundleIdentifier ?? ""])
        if let tok = AuthStore.shared.accessToken {
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - CallKit

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.endActiveCall() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            do {
                try await self.connectWebRTC()
                action.fulfill()
            } catch {
                action.fail()
                self.callState = "failed: \(error.localizedDescription)"
                Haptics.error()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.endActiveCall()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        WebRTCClient.activateAudioSession(audioSession)
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        WebRTCClient.deactivateAudioSession(audioSession)
    }
}

extension URLRequest {
    /// POST factory (avoids ambiguity with Foundation's availability-gated
    /// init(url:method:) — that one is iOS 16+ on some SDK paths).
    init(postTo url: URL) {
        self.init(url: url)
        httpMethod = "POST"
    }
}
