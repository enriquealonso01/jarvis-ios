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
    /// Latest gateway state pushed over the app data channel ("hello",
    /// "state", "transcript", "metrics" messages) — surfaced on the Calls tab.
    @Published var sessionInfo: String = ""
    @Published var lastTranscript: String?

    private var callController: CXCallController?
    private var provider: CXProvider?
    private var webRTC: WebRTCClient?
    /// lastPayload of the call currently being answered (read before WebRTC connect)
    private(set) var pendingAnswerPayload: VoIPPayload?
    /// Call-log bookkeeping for the live call (entry id + wall-clock start).
    private var logEntryID: String?
    private var callStart: Date?
    /// call_id -> end time for calls that JUST finished. APNs re-delivers
    /// pushes (at-least-once) and those retries can arrive AFTER the call was
    /// answered/ended — the active-call dedupe guard no longer matches then
    /// (activeCallUUID is nil) and the phone RANG AGAIN for a dead call.
    /// A call_id seen here within the window is acknowledged + ended without
    /// ringing (no second log entry either — the original entry exists).
    private var recentlyEndedCallIDs: [String: Date] = [:]
    private static let redeliveryWindow: TimeInterval = 10 * 60

    /// "Call me" button: the outgoing log entry was already written by the
    /// Calls tab — adopt it so endActiveCall stamps its outcome/duration.
    func trackOutgoingLog(entryID: String) {
        logEntryID = entryID
        callStart = Date()
    }

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

    /// Last PushKit token seen, persisted so registration can be RE-KICKED
    /// after the launch-time retry loop has burned out (see
    /// retryDeviceRegistration — the fresh-install day-one seam).
    private static let tokenKey = "jarvis.push.voiptoken"

    /// Re-attempt /register using the STORED PushKit token. Called when
    /// isAuthed flips true (password login OR manual token in Settings).
    ///
    /// Why this exists: on a fresh install the PushKit token arrives at
    /// launch — while the user is still on Setup/Login, BEFORE any Bearer
    /// exists — so the launch-time retry loop (5 attempts, ~30s) exhausts
    /// unauthenticated and gives up. The user then spends minutes on the
    /// login round trip; without this re-kick the bridge never learns the
    /// token until the NEXT cold launch, `device_registered` stays false,
    /// and "ring this phone" is dead on day one even though the user did
    /// everything right. Each attempt re-reads the CURRENT access token, so
    /// this call lands the registration the moment auth exists.
    func retryDeviceRegistration() async {
        guard let token = UserDefaults.standard.string(forKey: Self.tokenKey),
              !token.isEmpty else { return }
        await sendDeviceToken(token)
    }

    // MARK: Incoming push (called from AppDelegate)

    func handleVoIPPayload(_ payload: [AnyHashable: Any], onReported: (() -> Void)? = nil) {
        let p = VoIPPayload(
            reason: payload["reason"] as? String ?? "JARVIS call",
            callID: payload["call_id"] as? String ?? UUID().uuidString.prefix(8).description,
            gatewayWS: payload["gateway_ws"] as? String ?? "/voice-gw",
            scheduledBy: payload["scheduled_by"] as? String
        )
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "JARVIS")
        update.hasVideo = false
        update.localizedCallerName = "JARVIS"

        lastPayload = p
        // Post-end redelivery guard: a push for a call that JUST ended (in any
        // direction) must not ring the phone again — whether we're idle OR in
        // the middle of another call. Apple still requires every VoIP push to
        // reach CallKit, so report + immediately end; nothing is logged (the
        // original entry exists and already has its outcome).
        recentlyEndedCallIDs = recentlyEndedCallIDs.filter {
            Date().timeIntervalSince($0.value) < Self.redeliveryWindow
        }
        if recentlyEndedCallIDs[p.callID] != nil {
            let dedupeID = UUID()
            provider?.reportNewIncomingCall(with: dedupeID, update: update) { [weak self] _ in
                self?.provider?.reportCall(with: dedupeID, endedAt: Date(), reason: .remoteEnded)
                onReported?()
            }
            return
        }
        // Re-delivery guard: APNs is at-least-once and the bridge retries, so
        // the SAME call_id can wake us while that call is already ringing or
        // active. Reporting it again under a NEW uuid stacks a second CallKit
        // call on top of the live one and (worse) overwrites logEntryID, so
        // the real entry never gets its outcome stamp.
        if let existing = activeCallUUID, pendingAnswerPayload?.callID == p.callID {
            // Same call re-delivered: re-report with the SAME uuid (CallKit
            // treats it as a duplicate for an existing call) so the report
            // handler still runs and PushKit's completion resolves — Apple
            // requires every VoIP push to reach CallKit.
            provider?.reportNewIncomingCall(with: existing, update: update) { [weak self] error in
                if let error { print("[CallManager] duplicate report rejected: \(error)") }
                onReported?()
            }
            return
        }
        if activeCallUUID != nil {
            // A DIFFERENT call while one is live: one call at a time —
            // acknowledge the report (Apple contract) and end it immediately;
            // the user's live call stays untouched. Logged as missed.
            let bumpedID = UUID()
            let bumpUpdate = update
            let bumpReason = p.reason
            provider?.reportNewIncomingCall(with: bumpedID, update: bumpUpdate) { [weak self] _ in
                self?.provider?.reportCall(with: bumpedID, endedAt: Date(), reason: .remoteEnded)
                onReported?()
            }
            let bumpEntry = CallLogStore.shared.add(reason: bumpReason, outgoing: false)
            CallLogStore.shared.finish(id: bumpEntry, outcome: "missed")
            // Remember THIS push's call_id too: the bridge re-delivers VoIP
            // pushes (at-least-once), so without this every retry of the
            // bumped call rings/logs ANOTHER phantom "missed" entry while the
            // live call continues (one per retry, 10-min window).
            recentlyEndedCallIDs[p.callID] = Date()
            return
        }
        pendingAnswerPayload = p
        // Persistent log: record the incoming call even if it's never answered
        // (PushKit may wake us while killed; this is the only trace it happened).
        // Outcome is stamped later: "answered" on connect, "missed" on decline.
        logEntryID = CallLogStore.shared.add(reason: p.reason, outgoing: false)

        let uuid = UUID()
        activeCallUUID = uuid
        setupCallUI()
        callState = "ringing"
        // Report BEFORE returning from the VoIP push callback (hard requirement).
        // The PushKit completion fires only when CallKit ACCEPTS the report —
        // resolving it earlier is the classic crash-and-wedge (killed-app wake).
        provider?.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error { print("[CallManager] report incoming failed: \(error)") }
            onReported?()
        }
    }

    // MARK: Outgoing call ("Talk to JARVIS" — app-initiated, no APNs needed)

    /// Places a DIRECT call from the app: we drive CallKit's start-call
    /// action ourselves and dial the voice gateway immediately (no VoIP
    /// push involved). This is the path that works before the APNs p8 is
    /// installed, and it reuses the exact same WebRTC connect as answering.
    func placeDirectCall() async {
        guard activeCallUUID == nil else { return } // one call at a time
        let uuid = UUID()
        activeCallUUID = uuid
        pendingAnswerPayload = VoIPPayload(
            reason: "JARVIS call (from iOS app)",
            callID: uuid.uuidString.prefix(8).description,
            gatewayWS: "/voice-gw",
            scheduledBy: "ios-app-direct")
        logEntryID = CallLogStore.shared.add(reason: "JARVIS call (from iOS app)", outgoing: true)
        setupCallUI()
        callState = "dialing"
        let handle = CXHandle(type: .generic, value: "JARVIS")
        let start = CXStartCallAction(call: uuid, handle: handle)
        start.isVideo = false
        let transaction = CXTransaction(action: start)
        callController?.request(transaction) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.handleConnectionFailure(error.localizedDescription)
                }
                // On success we wait for perform(_:CXStartCallAction) — the
                // actual WebRTC dial happens there (CallKit contract).
            }
        }
    }

    /// Shared CallKit UI setup (provider + controller) for both directions.
    private func setupCallUI() {
        guard provider == nil else { return }
        let config = CXProviderConfiguration(localizedName: "JARVIS")
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        let prov = CXProvider(configuration: config)
        // Xcode 26 SDK: CXProvider.delegate became ObjC-direct and is no
        // longer visible to Swift — setDelegate(_:queue:) is the exposed API.
        prov.setDelegate(self, queue: nil)
        provider = prov
        callController = CXCallController()
    }

    // MARK: Answer / end (driven by CXProviderDelegate)

    private func connectWebRTC() async throws {
        guard let payload = pendingAnswerPayload else { return }
        callState = "connecting"
        callStart = Date()
        let base = ServerConfig.shared.config.voiceGWURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let offerURL = base + payload.gatewayWS + "/api/offer"
        let client = try await WebRTCClient.connect(offerURL: offerURL,
                                                    tokenProvider: { @Sendable in try await AuthStore.shared.validAccessToken() },
                                                    requestData: ["surface": "ios", "reason": payload.reason])
        // Gateway app messages ride the WebRTC data channel (same as the CC
        // voice page): hello carries brain/tts/stt, "state" drives the call
        // state label, transcripts show what JARVIS said.
        // The callback fires on the WebRTC queue with a non-Sendable [String:
        // Any] dict; re-box it as @Sendable before the MainActor hop.
        client.onAppMessage = { [weak self] msg in
            let sendableMsg = msg as NSDictionary as? [String: Any] ?? msg
            nonisolated(unsafe) let boxedMsg = sendableMsg
            Task { @MainActor in self?.handleAppMessage(boxedMsg) }
        }
        // Terminal ICE failure (never reached connected): fail the call state,
        // stamp the log, and drop the CallKit call instead of hanging.
        client.onConnectionFailed = { [weak self] why in
            nonisolated(unsafe) let boxedWhy = why
            Task { @MainActor in self?.handleConnectionFailure(boxedWhy) }
        }
        webRTC = client
        // Connect deadline: the call is only "active" once media actually
        // flows. If ICE never connects (dead gateway, NAT mismatch, network
        // drop), this throws after 15s and the caller's catch path fails the
        // call — no more "answered" log entries for calls that never rang.
        do {
            try await client.waitUntilConnected(timeout: 15)
        } catch {
            client.hangup()
            webRTC = nil
            throw error
        }
        callState = "active"
        CallLogStore.shared.finish(id: logEntryID, outcome: "answered")
        Haptics.success()
    }

    /// ICE reached a terminal failed/closed/disconnected state without ever
    /// connecting: surface the failure, stamp the log, tear the call down.
    private func handleConnectionFailure(_ why: String) {
        guard activeCallUUID != nil else { return } // already ended/hangup path
        guard !callState.hasPrefix("failed") else { return }
        callState = "failed: \(why)"
        CallLogStore.shared.finish(id: logEntryID, outcome: "failed")
        logEntryID = nil
        callStart = nil
        Haptics.error()
        if let uuid = activeCallUUID { provider?.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
        webRTC?.hangup()
        webRTC = nil
        // Same post-end redelivery memory for the failure path.
        if let p = pendingAnswerPayload { recentlyEndedCallIDs[p.callID] = Date() }
        pendingAnswerPayload = nil
        activeCallUUID = nil
        sessionInfo = ""
        lastTranscript = nil
    }

    private func handleAppMessage(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "hello":
            let brain = (msg["brain"] as? String ?? "").split(separator: ":").last.map(String.init) ?? ""
            sessionInfo = brain.isEmpty ? "connected" : "connected · \(brain)"
        case "state":
            let st = msg["state"] as? String ?? ""
            let label = msg["label"] as? String
            if st == "error" {
                // Gateway pipeline died mid-call (session.py now pushes this
                // on a crash). Fail the call properly: CallKit ended + log
                // stamp + teardown — never leave the phone on a dead line.
                handleConnectionFailure(label ?? "gateway session error")
            }
            else if st == "speaking" { callState = "active · speaking" }
            else if st == "working" { callState = label.map { "active · \($0)" } ?? "active · working" }
            else { sessionInfo = label ?? st }
        case "transcript":
            if msg["role"] as? String == "assistant", let text = msg["text"] as? String {
                lastTranscript = text
            }
        default:
            break
        }
    }

    func endActiveCall() {
        // Stamp the log with outcome + duration before tearing down.
        if callState.hasPrefix("failed") {
            // handleConnectionFailure ALREADY stamped this entry "failed" and
            // cleared logEntryID. Stamping again with id:nil hits CallLogStore's
            // "latest open entry" fallback — which, if a new call started after
            // the failure (or one is ringing now), mis-stamps THAT entry as
            // "failed". Only stamp when we still own the entry.
            if let id = logEntryID { CallLogStore.shared.finish(id: id, outcome: "failed") }
        } else if let start = callStart, callState == "active" || callState.hasPrefix("active") {
            CallLogStore.shared.finish(id: logEntryID, outcome: "ended",
                                       durationSeconds: max(0, Int(Date().timeIntervalSince(start))))
        } else if callState == "ringing" || callState == "connecting" || callState == "dialing" {
            // Never picked up (declined in CallKit, or push woke us and the
            // user let it ring out).
            CallLogStore.shared.finish(id: logEntryID, outcome: "missed")
        }
        logEntryID = nil
        callStart = nil
        if let uuid = activeCallUUID { provider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded) }
        webRTC?.hangup()
        webRTC = nil
        // Remember this call_id so a late APNs re-delivery can't ring again.
        if let p = pendingAnswerPayload { recentlyEndedCallIDs[p.callID] = Date() }
        pendingAnswerPayload = nil
        activeCallUUID = nil
        callState = "idle"
        sessionInfo = ""
        lastTranscript = nil
    }
}

// MARK: - PushKit

extension CallManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        // Persist BEFORE registering: retryDeviceRegistration() re-kicks from
        // this stored copy when auth flips later in the session (rotation —
        // PushKit reissuing a token — just overwrites it and re-registers).
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        Task { await self.sendDeviceToken(token) }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        // PushKit's completion is a plain callback the system waits on from
        // its own queue; capturing it (invoked exactly once, inside CallKit's
        // report handler) is safe, but Swift 6.2's region check can't prove
        // it — bind before the MainActor hop (same pattern as the CXActions).
        nonisolated(unsafe) let reportCompletion = completion
        nonisolated(unsafe) let pushPayload = payload
        Task { @MainActor in
            // completion() is deferred until CallKit accepts the incoming-call
            // report (reportNewIncomingCall's own handler) — the Apple-required
            // ordering that keeps killed/locked wakeups from being wedged out.
            self.handleVoIPPayload(pushPayload.dictionaryPayload, onReported: reportCompletion)
        }
    }

    @MainActor
    private func sendDeviceToken(_ token: String) async {
        // /register accepts dual auth: the app sends its dashboard Bearer
        // (bridge-verified locally, same ladder as /call); agents use the
        // x-bridge-sig HMAC path.
        //
        // Registration RETRY: on a fresh install the PushKit token arrives at
        // launch — BEFORE the user has signed in — so the first attempt has
        // no Bearer and the bridge 401s it. Without a retry the bridge never
        // learns the token until the next cold launch and "ring this phone"
        // is dead on day one. Retry on an exponential backoff while the app
        // lives; each attempt re-reads the token so it upgrades itself to
        // authed the moment login completes.
        let cfg = ServerConfig.shared.config
        let url = URL(string: cfg.bridgeBaseURL + "/register")
        guard let url else { return }
        for attempt in 0..<5 {
            var req = URLRequest(postTo: url)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["device_token": token, "bundle_id": Bundle.main.bundleIdentifier ?? ""])
            if let tok = AuthStore.shared.accessToken {
                req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            }
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return // registered — the bridge now knows this device
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 2_000_000_000) // 2,4,8,16s
            }
        }
        // Exhausted (server down for the session): the next launch's
        // didUpdate credentials callback re-registers.
    }
}

// MARK: - CallKit

extension CallManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.endActiveCall() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // CXAction is internally synchronized and CallKit permits fulfilling
        // from any thread; the MainActor hop is only for CallManager's
        // published state. Bind the non-Sendable action once so Swift 6.2's
        // region check doesn't flag the capture (same as CXEndCallAction).
        nonisolated(unsafe) let answerAction = action
        Task { @MainActor in
            do {
                try await self.connectWebRTC()
                answerAction.fulfill()
            } catch {
                answerAction.fail()
                // Full teardown (CallKit ended + log + PC hangup + state
                // clear). Without clearing activeCallUUID the one-call-at-
                // a-time guard would block every future call attempt.
                self.handleConnectionFailure(error.localizedDescription)
            }
        }
    }

    /// Outgoing call: CallKit asks us to dial. Same WebRTC connect as
    /// answering an incoming push, driven by placeDirectCall().
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Bind the non-Sendable action once (same rationale as CXAnswerCallAction).
        nonisolated(unsafe) let startAction = action
        nonisolated(unsafe) let startProvider = provider
        Task { @MainActor in
            do {
                // CallKit contract: report the call as outgoing-connected so
                // the system audio UI engages, then connect media.
                startProvider.reportOutgoingCall(with: startAction.callUUID, connectedAt: Date())
                try await self.connectWebRTC()
                startAction.fulfill()
            } catch {
                startAction.fail()
                // Full teardown — same as the answer-fail path (09:02) and
                // ICE failures: without the reportCall(endedAt:) here the
                // failed dial lingered in CallKit/system UI, and without
                // clearing pendingAnswerPayload the next incoming push could
                // be misread as a re-delivery of this dead call.
                self.handleConnectionFailure(error.localizedDescription)
                self.pendingAnswerPayload = nil
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // CXAction is internally synchronized and CallKit permits fulfilling
        // from any thread; the MainActor hop is only for CallManager's
        // published state. Swift 6.2's region check can't see that the
        // non-Sendable action never escapes back into the caller's region,
        // so bind it once here.
        nonisolated(unsafe) let endAction = action
        Task { @MainActor in
            self.endActiveCall()
            endAction.fulfill()
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
