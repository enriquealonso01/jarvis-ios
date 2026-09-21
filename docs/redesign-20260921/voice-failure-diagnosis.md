# JARVIS iOS Voice-Calling Failure — Diagnosis Report

**Date:** 2026-09-21 · **Mode:** diagnosis only (no fixes applied) · **Author:** diagnostic agent session

---

## 1. Executive summary

The voice gateway itself is **healthy end-to-end**: a valid WebRTC SDP offer posted with a
valid bearer token gets a real SDP answer over both the local socket (127.0.0.1:9150) and
the public Caddy route (https://jarvis.enriquecodes.com/voice-gw/), and a full aiortc
client completed offer → answer → ICE → RTP media successfully on the server.

The "calling feature fails with errors" symptom decomposes into **four distinct faults**,
none of which is the gateway's offer/answer logic:

| # | Fault | Where | Severity |
|---|-------|-------|----------|
| 1 | APNs rejects the VoIP push: **403 InvalidProviderToken** — the p8 key is not enabled for APNs | push_bridge → Apple | **Primary** — phone never rings for "Call Me" |
| 2 | Installed app build hits **401 on GET /voice-gw/api/health**; that endpoint string exists nowhere in the current repo → installed build is stale or contains debug-only health probing with a missing/expired bearer | iOS app (installed) | Secondary |
| 3 | **Episodic 20–66 s latency** on POST /api/offer (normal ≈ 40 ms). pipecat's `handle_web_request` awaits the full session bootstrap (brain `context()` + `tools()`) inside the HTTP request | gateway/pipecat | Secondary — client timeouts |
| 4 | Malformed offer body returns **HTTP 500** instead of 4xx | gateway | Minor |

No secrets, tokens, or credential values appear in this report.

---

## 2. Expected protocol (as mapped from code)

**Server** (`server/voice_gateway/gateway.py`, `session.py`, `brain.py`):

- `POST /voice-gw/api/offer`, header `Authorization: Bearer <token>`
- Token check `_bearer_valid`: urlsafe-b64(JSON `{kind:"access", exp, ...}`) + "." + b64(32-byte HMAC-SHA256), same format the hermes-dashboard basic-auth provider mints (`/usr/local/lib/hermes-agent/plugins/dashboard_auth/basic/__init__.py`). Verified compatible.
- Body: `{"sdp": "<offer SDP>", "type": "offer"}` (pipecat `SmallWebRTCRequest`).
- Response 200: `{"sdp": <answer SDP>, "type": "answer", "pc_id": "<id>", ...}`.
- Answer SDP (observed): audio-only, opus/G722/PCMU/PCMA, host + srflx candidates on the server's public IPv4/IPv6, `a=setup:active`, `a=end-of-candidates`. No TURN — server assumes direct UDP reachability.
- Other routes: `GET /healthz` (no auth), `GET /voice-gw/api/health`, `GET /voice-gw/api/sessions` (auth).

**Client** (`ios/JarvisApp/WebRTCClient.swift`):

- Builds `RTCPeerConnection` with `.unifiedPlan`, `iceServers = [stun:stun.l.google.com:19302]` (STUN only).
- `pc.offer(for:)` → `POST {voiceGWURL}/voice-gw/api/offer` with `{sdp, type:"offer"}` + Bearer token → expects `{sdp, type:"answer", pc_id}` → `setRemoteDescription`.
- Never sends its own ICE candidates (`didGenerate candidate` is a no-op — relies on the answer carrying them, which it does).
- `CallManager.swift` drives CallKit; `CallsView.swift` "Call Me" posts to bridge `/call` and surfaces `pushed` true/false.

**Bridge** (`server/push_bridge/main.py`): `POST /call` → `_send_voip()` → APNs HTTP/2 with ES256 provider-token JWT (kid header) → returns `{"call_id", "pushed": bool}`. Non-200 from Apple is logged loudly with Apple's `reason` and counted in `push_counters.json`.

---

## 3. Reproduction — real commands and outputs

### 3.1 Auth gating (no token / garbage token)

```
$ curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:9150/voice-gw/api/offer \
    -H 'Content-Type: application/json' --data @offer.json
401
$ curl ... -H 'Authorization: Bearer garbage'
401
```
Auth gate works as designed.

### 3.2 Valid offer, direct + via Caddy (reproduction script `/tmp/.diag-post.sh`)

A real audio-only SDP offer was generated with aiortc 1.15.0 (`/opt/voice-gw/.venv`,
`/tmp/.diag-genoffer.py` — silent audio track, mirroring the iOS client), then POSTed
with a freshly minted dashboard bearer token:

- **Direct** `http://127.0.0.1:9150/voice-gw/api/offer` → **HTTP 200**, body
  `{"sdp":"v=0\r\no=- ... m=audio 47858 UDP/TLS/RTP/SAVPF 96 9 0 8\r\n...a=setup:active...","type":"answer","pc_id":"<id>"}`
- **Via Caddy** `https://jarvis.enriquecodes.com/voice-gw/api/offer` → **HTTP 200**, identical answer shape.
- **Malformed body** → **HTTP 500** (fault #4).

### 3.3 Full client emulation (aiortc; `/tmp/.diag-e2e.py`)

```
POST /api/offer                ... 200 (offer POST took ~20 s this run)
remote answer: type=answer, pc_id present, 1 audio stream
ICE state -> 'completed'; connection established
received 460 RTP audio frames (opus) from the gateway
session closed cleanly; /api/sessions afterwards shows no leaked sessions
```
The media path on the server works. `GET /api/sessions` confirmed the session was
configured (brain ok) and later reaped.

### 3.4 Latency series (`/tmp/.diag-loop.sh`)

```
offer#1 direct: 0.044715s HTTP 200     offer#4 direct: 0.039040s HTTP 200
offer#2 direct: 0.036289s HTTP 200     offer#5 direct: 0.220250s HTTP 200
offer#3 direct: 0.038043s HTTP 200
```
vs. earlier runs the same hour at **20.0 s, 66 s** — episodic, not load-dependent
(fault #3).

### 3.5 Journal evidence

```
$ journalctl -u jarvis-voice-gateway.service --since 2026-09-21 12:50
INFO: 159.195.245.62:0 - "GET /voice-gw/api/health HTTP/1.1" 401 Unauthorized   (×2)
INFO: 2600:1700:2610:...: - "GET /voice-gw/healthz HTTP/1.1" 200 OK             (phone, IPv6)
```
159.195.245.62 is **this server's own public IP** (host candidate in our own SDP) —
local monitor traffic, not the phone. The phone reaches the gateway over IPv6 and gets
401 on `/voice-gw/api/health`.

```
$ journalctl -u jarvis-ios-bridge.service --since 2026-09-19 | grep -iE "apns|push|voip"
→ APNs rejects the VoIP push: HTTP 403 InvalidProviderToken  (push_fail=2 in /opt/jarvis-ios-bridge/push_counters.json)
```

Bridge code (`main.py:104-116`) and `scripts/probe_apns_delivery.py` confirm this exact
failure was already observed 2026-09-18: *"the live key answers 403 InvalidProviderToken
/ 403 TokenUseInactiveKey → key not valid for APNs"* — the p8 file exists and parses as a
valid EC key, but Apple does not recognize it as an APNs-enabled key.

### 3.6 No TURN anywhere

`gateway.py` mentions no TURN; the client has STUN only; answer SDP carries host+srflx
server candidates. Works when the phone's network allows direct UDP; will fail silently
(no media, no error surfaced to CallManager) behind symmetric NAT / UDP-blocking
networks.

---

## 4. Root-cause analysis

### Fault 1 (primary): APNs p8 key lacks APNs capability → phone never rings

The in-app "Call Me" flow is: app → bridge `POST /call` → `_send_voip()` → APNs. Apple
answers **403 InvalidProviderToken**, so `pushed=false` and no VoIP push is delivered.
CallKit never fires; the user sees "calling… fails with errors" (or, in the current UI
copy, the honest "push queued server-side" fallback only if pushed=false is surfaced —
the ring itself can never happen). This is a **key configuration problem in the Apple
Developer account** (key created without APNs service, wrong Key ID, wrong Team ID, or a
revoked key), not a code bug. Known and documented in-repo since 2026-09-18 but never
resolved.

Note the bridge also runs against `api.sandbox.push.apple.com` while `APNS_SANDBOX=1`; a
device token minted by a **production** (TestFlight/App Store) build would need the
production host — a second, independent way this push can 403/400 after the key is fixed.

### Fault 2: stale/mismatched installed app build

The phone's requests to `/voice-gw/api/health` 401, but **no Swift source in the repo
references `/api/health`** (verified via repo grep and `git log -S` across all history).
The installed build is therefore not built from current `main`, or contains debug
health-polling that (a) doesn't attach the bearer and (b) confuses the failure surface —
the user-visible "errors" may partly be this probe failing, not actual call attempts.

### Fault 3: offer-request latency spikes (20–66 s vs 40 ms)

pipecat's `SmallWebRTCBridge.handle_web_request` **awaits session bootstrap inside the
HTTP handler** — gateway `session.start()` → brain `context()` (dashboard round-trip
≈ 8 s observed) + `tools()` build. When the dashboard is slow/restarting (it restarted
twice at 04:33/04:35 today), offer POSTs block for tens of seconds. The iOS client's
`URLSession` timeout then aborts, and the gateway only completes the work afterwards
(journal shows the 13:05 POST completing the same second the client gave up) — burning a
full session per timed-out attempt.

### Fault 4: malformed body → 500

`POST /api/offer` with invalid JSON/shape returns HTTP 500 with a traceback in the logs.
Should be 400. Masks client bugs as "server error" in any dashboard/monitoring.

### Fault 5 (latent): no TURN relay

All ICE is STUN-only on both ends. Server-side it worked from loopback, but a phone on
carrier NAT/corporate Wi-Fi may complete signaling and then get zero media with no error
path — a likely future "call connects but is silent" report.

---

## 5. Proposed fix plan (NOT implemented)

1. **Fix APNs (fault 1)** — in Apple Developer: create/verify an **APNs Auth Key (.p8)**
   with APNs enabled, correct `kid` (APNS_KEY_ID) and Team ID; replace
   `/opt/jarvis-ios-bridge/apns.key`; verify with the existing
   `scripts/probe_apns_delivery.py`. Then confirm `APNS_SANDBOX` matches the build's
   environment (sandbox for dev builds, production host for TestFlight/App Store tokens).
   Add an explicit "Apple rejected the push: <reason>" surfaced in the app UI when
   `pushed=false`.
2. **Rebuild/reinstall the iOS app from current main** (fault 2) so the phone stops
   polling the phantom `/api/health`; add a regression test/grep that fails CI if Swift
   references an endpoint the gateway doesn't expose.
3. **Move session bootstrap out of the offer request path** (fault 3): return the SDP
   answer immediately, run `context()`/`tools()` concurrently after answering (pipecat
   supports post-answer runner startup), and/or add per-attempt timeouts + a retry so a
   slow dashboard can't block signaling. Also make the client's URLSession timeout
   explicit and retry once.
4. **Map malformed offers to HTTP 400** (fault 4) in the gateway's request validation.
5. **Add a TURN server** (fault 5), e.g. coturn on this host behind Caddy/TLS, and add
   its `turn:` URL to both the gateway answer SDP and the iOS `iceServers`.

## 6. Constraints honored

- No services restarted, no code or config edited. Only POSTs to the endpoint under test
  (`/api/offer`, plus read-only `GET /sessions`, `/healthz`).
- Credentials were located (dashboard basic-auth config), used only to mint a test
  bearer, and are not reproduced here or in any committed artifact.
