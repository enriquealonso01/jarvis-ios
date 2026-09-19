# Gateway: native-client WebRTC access (backlog #6)

## What changed (2026-09-18)

The voice gateway (`/opt/voice-gw/gateway.py`, port 9150) auth gate now accepts
**both**:

1. Dashboard session cookie (`hermes_session_at=…`) — existing PWA/orb path,
   unchanged.
2. `Authorization: Bearer <access token>` — NEW native path for the iOS app.

The bearer token is the SAME stateless HMAC access token the dashboard's
`basic` provider mints in the RFC 8252 native flow the app already uses for
the Control Center API (`/auth/native/token`). The gateway verifies it
**locally** (it already holds `dashboard.basic_auth.secret` for its own
`_mint_session_token`), so no dashboard round-trip was added. Checks:
signature (HMAC-SHA256), `kind == "access"`, `exp` in the future. Refresh
tokens are rejected; tampered tokens are rejected; invalid/no auth → 401.

Verified live after restart (`scripts/probe_gateway_bearer_live.py`):
- valid bearer on `POST /voice-gw/api/offer` → passes gate (reaches SDP handler)
- invalid bearer → 401; no auth → 401; refresh-kind → 401
- cookie path still passes (no PWA regression); `/healthz` ok, brain realtime

## How the iOS app connects

The WebRTC surface is unchanged — same endpoint the CC orb uses:

```
POST https://jarvis.enriquecodes.com/voice-gw/api/offer
Authorization: Bearer <access token from Keychain>
Content-Type: application/json

{ "sdp": "<offer sdp>", "type": "offer" }
```

Response: `{ "sdp": "<answer sdp>", "type": "answer", "pc_id": "…" }` —
SmallWebRTC answer; the app sets it as the remote description. ICE: the
gateway hands out STUN (`stun:stun.l.google.com:19302`) in the SDP.

Subsequent per-call controls (all accept the same Bearer):
- `POST /voice-gw/api/say` `{pc_id, text}` — JARVIS speaks typed text
- `POST /voice-gw/api/hangup` `{pc_id}` — end the voice session (returns
  `{ok}`; hangs up if the session exists)

Optional in the offer body: `"request_data": {"surface": "ios", "reason":
"…"}`. The gateway then labels the voice session surface `ios` (instead of
`cc_pwa`) and speaks the reason naturally right after the greeting — this is
how a JARVIS-initiated call (VoIP push → answer) tells him why it rang.

Data channel (required, mirror of the CC voice page): after the answer is
set, the app creates an ordered data channel labeled `app` and sends a
literal `ping` TEXT string once per second (session liveness — pipecat
counts only text pings; a binary ping silently kills the keepalive). The
gateway pushes
JSON app messages back: `hello` (brain/tts/stt), `state`
(listening/thinking/working/speaking + label), `transcript`
(role user/assistant + text), `metrics`, `tool`, `reset`.

Note: access tokens live ~1h (dashboard TTL). On 401 the app refreshes via
`/auth/native/refresh` and retries once (same as CCClient already does).

## VoIP push payload contract (bridge → app)

```json
{ "reason": "Call about X", "call_id": "ab12cd34", "gateway_ws": "/voice-gw",
  "scheduled_by": "whatsapp-jarvis" }
```

`gateway_ws` is the URL path prefix for the offer endpoint on the configured
dashboard origin.
