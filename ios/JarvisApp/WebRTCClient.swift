import Foundation
import WebRTC
import AVFoundation

/// Backlog #4: native WebRTC client against the voice gateway's offer/answer
/// endpoint — the exact same surface the Control Center orb uses
/// (POST {gateway_ws}/api/offer with {sdp, type} → {sdp, type: "answer"}).
///
/// The gateway runs aiortc (SmallWebRTC). We use the Google WebRTC STS pod so
/// SDP munging needs are zero: audio-only, STUN from the answer, done.
final class WebRTCClient: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    private var factory: RTCPeerConnectionFactory!
    private var pc: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private let queue = DispatchQueue(label: "jarvis.webrtc")
    private var pcID: String?
    private var baseURL: String = ""
    private(set) var connected = false

    typealias TokenProvider = @Sendable () async throws -> String
    private var tokenProvider: TokenProvider!

    /// App data channel (label "app") — the same channel the CC voice page
    /// creates. The gateway's session pushes hello/state/transcript/metrics
    /// JSON over it and expects a literal "ping" string every ~1s as liveness.
    private var appChannel: RTCDataChannel?
    private var pingTimer: DispatchSourceTimer?
    /// Called (off-main) for every JSON app message the gateway sends.
    var onAppMessage: (@Sendable ([String: Any]) -> Void)?
    /// Called (off-main) when the peer connection reaches a terminal ICE
    /// state (failed/disconnected/closed) after connect — CallManager turns
    /// this into callState "failed: …" + a missed/failed log stamp instead of
    /// sitting in "connecting" forever.
    var onConnectionFailed: (@Sendable (String) -> Void)?
    /// Fired once when ICE first reaches connected/completed.
    var onConnected: (@Sendable () -> Void)?
    private var connectedFired = false
    /// Mid-call drop detection: ICE `.disconnected` AFTER we were connected
    /// is transient (network blip, Wi-Fi→cellular). Start a grace timer; if
    /// ICE returns to connected within it, cancel — otherwise the call is a
    /// dead line and must fail instead of showing "active" forever.
    private var disconnectGrace: DispatchSourceTimer?
    /// How long ICE may stay `.disconnected` before we declare the call dead.
    static let disconnectGraceSeconds: Int = 10

    nonisolated(unsafe) static var sharedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let enc = RTCDefaultVideoEncoderFactory()
        let dec = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)
    }()

    nonisolated(unsafe) static var activeAudioSession: AVAudioSession?

    /// Ask for mic permission BEFORE creating the offer. Without this the
    /// prompt can surface mid-call (or be silently denied after a prior
    /// rejection) and the call runs one-way / dead. Returns true if the mic
    /// is usable.
    static func ensureMicrophonePermission() async -> Bool {
        // iOS 17+: AVAudioApplication.requestRecordPermission is the
        // non-deprecated API; fall back to AVAudioSession's for older sims.
        if #available(iOS 17.0, *) {
            let granted: Bool = await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { ok in cont.resume(returning: ok) }
            }
            guard granted else { return false }
        } else {
            let granted: Bool = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in cont.resume(returning: ok) }
            }
            guard granted else { return false }
        }
        // Pre-warm the session so the first audio unit start happens with
        // permission already granted and the category set.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        return true
    }


    static func activateAudioSession(_ session: AVAudioSession) {
        activeAudioSession = session
        try? session.setMode(.voiceChat)
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    static func deactivateAudioSession(_ session: AVAudioSession) {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        activeAudioSession = nil
    }

    /// Full connect: build PC, create offer, POST to the gateway, set answer.
    static func connect(offerURL: String, tokenProvider: @escaping TokenProvider,
                        requestData: [String: Any] = [:]) async throws -> WebRTCClient {
        let client = WebRTCClient()
        client.baseURL = offerURL
        client.tokenProvider = tokenProvider

        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan

        // Mic permission + session category BEFORE the offer — otherwise the
        // prompt can land mid-call or the session runs one-way.
        guard await ensureMicrophonePermission() else {
            throw CallError.microphoneDenied
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let pc = sharedFactory.peerConnection(with: config, constraints: constraints, delegate: client)
        client.pc = pc
        guard let pc else { throw CallError.sdp }

        // Audio: mic in, receiver out.
        let audioSource = sharedFactory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = sharedFactory.audioTrack(with: audioSource, trackId: "jarvis-audio")
        client.localAudioTrack = track
        pc.add(track, streamIds: ["jarvis-stream"])

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil)
        let offerSDPString: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            pc.offer(for: offerConstraints) { sdp, err in
                if let sdp {
                    // Resume with the SDP string (Sendable) — RTCSessionDescription
                    // is a non-Sendable ObjC class and can't cross a continuation.
                    cont.resume(returning: sdp.sdp)
                } else { cont.resume(throwing: err ?? CallError.sdp) }
            }
        }
        let offerSDP = RTCSessionDescription(type: .offer, sdp: offerSDPString)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offerSDP) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }

        // POST {sdp, type} → {sdp, type:"answer", pc_id}
        let token = try await tokenProvider()
        guard let offerURL = URL(string: offerURL) else { throw CallError.gateway("bad offer URL") }
        var req = URLRequest(url: offerURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var payload: [String: Any] = [
            "sdp": offerSDP.sdp,
            "type": "offer",
        ]
        if !requestData.isEmpty { payload["request_data"] = requestData }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CallError.gateway("offer HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        struct Answer: Decodable { let sdp: String; let type: String; let pc_id: String? }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        client.pcID = answer.pc_id
        let remote = RTCSessionDescription(type: .answer, sdp: answer.sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(remote) { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }

        // App data channel + liveness pings (mirror of voice_page.html):
        // the gateway session only treats the client as on-the-line while
        // literal "ping" strings arrive, and it pushes hello/state/transcript
        // JSON back over this channel.
        client.openAppChannel()
        return client
    }

    /// Suspends until ICE reaches connected/completed, or throws after
    /// `timeout` seconds. Polled at 100 ms — fine for one-shot call setup.
    func waitUntilConnected(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !connected {
            if Date() > deadline {
                throw CallError.gateway("no media connection within \(Int(timeout))s")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func openAppChannel() {
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let dc = pc?.dataChannel(forLabel: "app", configuration: config) else { return }
        dc.delegate = self
        appChannel = dc
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "jarvis.webrtc.ping"))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let dc = self.appChannel, dc.readyState == .open else { return }
            // isBinary MUST stay false: the gateway's keepalive (pipecat
            // SmallWebRTCConnection) only counts TEXT frames that start with
            // "ping" — a binary ping misses the keepalive branch, throws in
            // its json.loads, and is error-logged every second while the
            // session's liveness clock never advances (voice_page.html and
            // probe_webrtc_native.py both send text; we must match).
            dc.sendData(RTCDataBuffer(data: Data("ping".utf8), isBinary: false))
        }
        timer.resume()
        pingTimer = timer
    }

    private func handleAppMessageJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return }
        onAppMessage?(dict)
    }

    enum CallError: LocalizedError {
        case sdp
        case microphoneDenied
        case gateway(String)
        var errorDescription: String? {
            switch self {
            case .sdp: return "could not build WebRTC offer"
            case .microphoneDenied: return "microphone access denied — enable it in Settings to place calls"
            case .gateway(let why): return "gateway: \(why)"
            }
        }
    }

    /// Speak text through the live session (gateway /api/say).
    func say(_ text: String) async {
        guard let pcID else { return }
        _ = try? await post(path: "/api/say", body: ["pc_id": pcID, "text": text])
    }

    /// End the voice session (gateway /api/hangup) and tear down.
    func hangup() {
        pingTimer?.cancel()
        pingTimer = nil
        cancelDisconnectGrace()
        appChannel?.close()
        appChannel = nil
        if let pcID {
            Task { _ = try? await self.post(path: "/api/hangup", body: ["pc_id": pcID]) }
        }
        pc?.close()
        pc = nil
        connected = false
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        let urlStr = baseURL.replacingOccurrences(of: "/api/offer", with: path)
        guard let url = URL(string: urlStr) else { throw CallError.gateway("bad URL: \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try? await tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let wasConnected = connected
        connected = (newState == .connected || newState == .completed)
        if connected && !wasConnected && !connectedFired {
            connectedFired = true
            onConnected?()
        }
        switch newState {
        case .connected, .completed:
            // ICE recovered (blip ended) — stand the grace timer down.
            cancelDisconnectGrace()
        case .failed:
            cancelDisconnectGrace()
            onConnectionFailed?("media connection failed")
        case .closed:
            cancelDisconnectGrace()
            // Only terminal if we never got connected (a normal hangup closes
            // the PC deliberately and CallManager already handles that path).
            if !connected { onConnectionFailed?("media connection closed before connecting") }
        case .disconnected:
            // Transient while it lasts. If we NEVER connected it's terminal
            // immediately; if we had, allow a grace window — a Wi-Fi→cellular
            // handoff usually recovers within seconds. Expiry = dead line.
            if !connected {
                onConnectionFailed?("media connection lost before connecting")
            } else {
                startDisconnectGrace()
            }
        default:
            break
        }
    }

    // MARK: Mid-call drop detection

    private func startDisconnectGrace() {
        guard disconnectGrace == nil else { return } // already counting down
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(Self.disconnectGraceSeconds))
        t.setEventHandler { [weak self] in
            guard let self, self.connected == false, self.disconnectGrace != nil else { return }
            self.cancelDisconnectGrace()
            self.onConnectionFailed?("media connection lost (no recovery within \(Self.disconnectGraceSeconds)s)")
        }
        t.resume()
        disconnectGrace = t
    }

    private func cancelDisconnectGrace() {
        disconnectGrace?.cancel()
        disconnectGrace = nil
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // Required by RTCPeerConnectionDelegate (M130). The gateway client
        // creates its own "app" data channel in openAppChannel(); if the
        // peer opens one instead, adopt it so app messages still flow.
        dataChannel.delegate = self
        appChannel = dataChannel
    }

    // MARK: RTCDataChannelDelegate (the gateway's "app" channel)

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        // nothing to do; the ping timer checks readyState before each send
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        handleAppMessageJSON(buffer.data)
    }
}
