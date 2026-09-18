# ARCHITECTURE

One JARVIS box (NetCup vServer) serves everything. Enrique's iPhone talks to it
over the public Caddy host; agents talk over loopback with HMAC.

```
iPhone (TestFlight app, com.enriquecodes.jarvis)
  │  HTTPS (Bearer = dashboard access token in Keychain)
  ▼
Caddy  jarvis.enriquecodes.com
  ├── /bridge/*      → 127.0.0.1:9160  (prefix stripped)   push bridge
  ├── /voice-gw/*    → 127.0.0.1:9150                      voice gateway
  └── /*             → hermes-dashboard (CC web/API, auth)
```

## Components

### iOS app (`ios/`, SwiftUI, iOS 18+ target, dark-only)
- **Auth** (`AuthStore.swift`): RFC 8252 native PKCE against the dashboard
  `basic` provider → stateless HMAC access token (+ refresh) in Keychain.
  This SAME bearer authorizes the bridge and the gateway's WebRTC offer.
- **Home** (`HomeView.swift`): CC vitals/LLM usage/crons/current work via the
  dashboard control-center API (same shapes as the web CC).
- **Chats** (`ChatsView.swift`): dispatch board projects → thread history →
  send via the dashboard agent chat endpoint.
- **Secrets** (`SecretsView.swift`): named-secret manager; values live ONLY in
  `/opt/jarvis-ios-bridge/secrets.json` (0600) server-side; UI shows masked
  previews. Optional Face ID gate.
- **Calls** (`CallManager.swift`, `WebRTCClient.swift`, `CallsView.swift`):
  PushKit → CallKit full-screen; answering opens a WebRTC audio offer/answer
  with the voice gateway (`POST {voice-gw}/api/offer`, Bearer). "Call me"
  button POSTs bridge `/call`; scheduled list/cancel against `/schedule/*`.

### Push bridge (`server/push_bridge/main.py`, systemd `jarvis-ios-bridge`, :9160)
FastAPI. Serves from the repo checkout
(`WorkingDirectory=/root/projects/jarvis-ios/server/push_bridge`): a repo edit
IS the deploy after a restart; last-known-good copy lives in
`/opt/jarvis-ios-bridge-lkg/`. State dir `/opt/jarvis-ios-bridge/`
(shared_secret, apns.env, apns.key, scheduled_calls.json, secrets.json — all
root-only 0600). Auth ladder on every
route: `x-bridge-sig` HMAC-SHA256(secret, raw body) **or** dashboard Bearer
(gateway-identical verify: sig + kind=access + exp, checked locally).
- `/call` → APNs VoIP push (payload: reason, call_id, gateway_ws:"/voice-gw").
  `apns-topic` MUST equal the app bundle ID (com.enriquecodes.jarvis); when the
  p8 isn't installed it logs-and-acks (`pushed:false`) so agents can develop.
  Any APNs non-200 is logged LOUD (`[bridge] APNs push REJECTED: HTTP <code>
  <reason>`) — a rejected push must never masquerade as "no device yet".
- `/schedule`, `/schedule/list`, `/schedule/cancel` → scheduler loop (20s tick)
  fires `/call` when due; device_token snapshotted at schedule time
  (server-side only — /schedule/list strips it from responses).
- `/register` → app POSTs its APNs token on launch; persisted to apns.env and
  auto-injected into every push.
- `/secrets`, `/secrets/set`, `/secrets/delete` → named-secret store.
Deployed code = repo working tree (systemd WorkingDirectory points here);
restarts only after `py_compile` passes + `/health` verified.

### Voice gateway (`/opt/voice-gw/gateway.py`, systemd `jarvis-voice-gateway`, :9150)
Same Pipecat pipeline for every surface (web orb, PWA, native app):
WebRTC offer/answer at `/api/offer` (auth: dashboard cookie OR Bearer access
token — added 2026-09-18 for native clients), `/api/say`, `/api/hangup`,
`/healthz`. The iOS payload field `gateway_ws:"/voice-gw"` tells the app which
public path prefixes to use. Repo copies `server/voice_gateway/gateway.py` +
`server/voice_gateway/session.py` are synced mirrors for traceability; edits
go through py_compile gate + restart + healthz verify (last-known-good
snapshot kept). On a mid-call pipeline crash, `VoiceSession._run()` pushes
`{type:"state", state:"error", label}` over the app data channel before
closing (added 2026-09-18) — the iOS app turns that into CallKit call-ended +
a "failed" call-log stamp instead of dead air.

Native-client specifics (added 2026-09-18, build-loop audit): the iOS app
sends `request_data: {surface: "ios", reason}` in its offer body. The gateway
labels the session surface `ios` (metrics/CC show it distinctly from
`cc_pwa`) and, if a `reason` is present, injects it ~6s after connect as a
spoken line so JARVIS opens the call with why he's calling. The app ALSO
creates the SmallWebRTC "app" data channel (label `app`, ordered) and sends a
literal `ping` string every second — same contract as voice_page.html. The
gateway pushes `hello` / `state` / `transcript` / `metrics` JSON back over it;
`WebRTCClient.onAppMessage` routes those into `CallManager` (call-state label
+ last transcript on the Calls tab). A native call without the data channel
would look dead to the session monitor and get no live state — don't remove it.

### Dashboard (hermes-dashboard)
Serves the CC web UI + the API the app mirrors (vitals, dispatch, auth/native
PKCE endpoints). Agents never restart it unless a router file compiles AND
/control + healthz are verified after.

## Call flow (the core mission)
1. Any agent (WhatsApp/voice/loop) HMAC-POSTs `/call {reason}` (or `/schedule`).
2. Bridge signs ES256 JWT with the APNs p8 → VoIP push to the registered
   device token, payload `{reason, call_id, gateway_ws}`.
3. iOS PushKit wakes the app (even killed/locked) → CallKit incoming screen.
4. On answer, `WebRTCClient` POSTs an audio offer to
   `https://jarvis.enriquecodes.com/voice-gw/api/offer` with the Keychain
   bearer → gateway answers → JARVIS speaks with the reason as context.

## Verifying the native path (no phone needed)
`scripts/verify_all.sh` step 6/6 runs `scripts/probe_webrtc_native.py`: a real
aiortc WebRTC client (venv `/root/venvs/webrtc-probe`, aiortc + pyyaml) mints a
dashboard Bearer, POSTs an offer with `request_data {surface:"ios", reason}` to
the LIVE gateway, connects ICE, opens the `app` data channel, pings at 1 Hz,
and asserts the gateway's audio track + `hello` arrive — the exact contract
the iOS `WebRTCClient` implements. It hangs its throwaway session up at the
end and is read-only otherwise. If the probe ever FAILs after a gateway
change, the native call path is broken regardless of what the auth-gate check
(step 3) says.

## What only Enrique can do (the gated ladder)
Xcode build on the Mac → TestFlight upload (fastlane lane or manual) → create
the APNs p8 key and hand it over for install. See docs/BUILD.md, FASTLANE.md,
API.md "Pending".
