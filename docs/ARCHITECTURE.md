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
FastAPI. State dir `/opt/jarvis-ios-bridge/` (shared_secret, apns.env,
scheduled_calls.json, secrets.json — all 0600). Auth ladder on every route:
`x-bridge-sig` HMAC-SHA256(secret, raw body) **or** dashboard Bearer (gateway-
identical verify: sig + kind=access + exp, checked locally).
- `/call` → APNs VoIP push (payload: reason, call_id, gateway_ws:"/voice-gw").
  `apns-topic` MUST equal the app bundle ID (com.enriquecodes.jarvis); when the
  p8 isn't installed it logs-and-acks (`pushed:false`) so agents can develop.
- `/schedule`, `/schedule/list`, `/schedule/cancel` → scheduler loop (20s tick)
  fires `/call` when due; device_token snapshotted at schedule time.
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
public path prefixes to use. Repo copy `server/voice_gateway/gateway.py` is a
synced mirror for traceability; edits go through py_compile gate + restart +
healthz verify (last-known-good snapshot kept).

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

## What only Enrique can do (the gated ladder)
Xcode build on the Mac → TestFlight upload (fastlane lane or manual) → create
the APNs p8 key and hand it over for install. See docs/BUILD.md, FASTLANE.md,
API.md "Pending".
