# Push Bridge API (127.0.0.1:9160, systemd `jarvis-ios-bridge`)

All POSTs require header `x-bridge-sig`: HMAC-SHA256 of the exact raw request body,
keyed by the shared secret in /opt/jarvis-ios-bridge/shared_secret (root-only).

- `POST /call` `{reason, scheduled_by?}` -> `{call_id, pushed}`. Fires VoIP push now.
  `pushed:false` = APNs p8 not yet configured (bridge still queues/logs).
- `POST /schedule` `{at_iso (ISO-8601, prefer +00:00), reason, scheduled_by?}` -> `{call_id, at}`.
  Internal scheduler fires when due (20s tick).
- `POST /register` `{device_token, bundle_id?}` -> `{registered, token_len}`.
  App calls this on launch with its APNs token. Persisted as `DEVICE_TOKEN=...` in
  /opt/jarvis-ios-bridge/apns.env (0600) and auto-injected into every /call push and
  every /schedule entry (`device_token` field, snapshotted at schedule time —
  kept server-side only, never listed back by /schedule/list).
- `GET /schedule/list` -> `{scheduled: [{call_id, at_iso, reason, scheduled_by}]}`.
  (The snapshotted `device_token` and the internal `failures` counter are
  STRIPPED from every entry — the push-delivery secret is only used by the
  scheduler fire path, never returned to clients. Fixed 2026-09-18.)
  GETs authenticate via HMAC over an empty body (`sig = HMAC-SHA256(secret, b"")`)
  OR the iOS app's `Authorization: Bearer <dashboard token>` (added with backlog #4).
- `POST /schedule/cancel` `{call_id?}` -> `{cancelled: N}`. With call_id cancels that one;
  with empty body `{}` cancels all pending.
- `GET /health` -> `{ok, apns_configured, device_registered, scheduled}`.
  `device_registered` = the phone has completed POST /register (boolean
  presence signal only — the token itself is never exposed here).

## Named secrets (backlog #3, added 2026-09-18)

Values persist server-side only (`/opt/jarvis-ios-bridge/secrets.json`, 0600) and
are NEVER returned by any endpoint — only names + masked previews. Auth is dual:

- agents: `x-bridge-sig` HMAC (same as every other endpoint), or
- the iOS app: `Authorization: Bearer <access token>` — the same stateless HMAC
  access token the dashboard `basic` provider mints (gateway-identical verify
  ladder: sig + kind=access + exp, checked locally, no dashboard round-trip).

Public path via Caddy: `https://jarvis.enriquecodes.com/bridge/secrets` (the
`/bridge/*` route proxies to :9160, prefix stripped).

- `GET /secrets` -> `{secrets: [{name, masked, length, updated_at, updated_by}]}`.
  GETs authenticate via HMAC over empty body OR Bearer.
- `POST /secrets/set` `{name, value, updated_by?}` -> `{ok, name, created, stored}`.
  Upsert; rejects empty values and `=` in names (422).
- `POST /secrets/delete` `{name}` -> `{ok, deleted}`.

Agent recipe (e.g. store the APNs p8 fields without touching git):
```
secret=$(cat /opt/jarvis-ios-bridge/shared_secret)
body='{"name":"APNS_KEY_ID","value":"ABC123","updated_by":"jarvis-agent"}'
sig=$(printf %s "$body" | openssl dgst -sha256 -hmac "$secret" -hex | cut -d' ' -f2)
curl -s -X POST http://127.0.0.1:9160/secrets/set -H "x-bridge-sig: $sig" -H "Content-Type: application/json" -d "$body"
```

## Calling Enrique (for WhatsApp/voice JARVIS tools)
1. `secret=$(cat /opt/jarvis-ios-bridge/shared_secret)`
2. `body='{"reason":"Call about X","scheduled_by":"whatsapp-jarvis"}'`
3. `sig=$(printf %s "$body" | openssl dgst -sha256 -hmac "$secret" -hex | cut -d' ' -f2)`
4. `curl -s -X POST http://127.0.0.1:9160/call -H "Content-Type: application/json" -H "x-bridge-sig: $sig" -d "$body"`

Note (backlog #4): `/call`, `/schedule`, `/schedule/cancel` and `/schedule/list`
also accept the iOS app's dashboard Bearer token (same dual-auth ladder as
`/secrets`), so the app calls these directly. The VoIP push payload now always
carries `gateway_ws: "/voice-gw"` per the contract in docs/GATEWAY.md.

## Pending until Enrique does his part
- APNs: create .p8 key in App Store Connect (Keys tab), download, then JARVIS stores it at
  /opt/jarvis-ios-bridge/apns.key (root 600) and writes /opt/jarvis-ios-bridge/apns.env with
  APNS_KEY_ID, APNS_TEAM_ID, APNS_P8_PATH, APNS_BUNDLE_ID=com.enriquecodes.jarvis, APNS_SANDBOX=0.
  IMPORTANT: APNS_BUNDLE_ID must equal the app's bundle identifier
  (com.enriquecodes.jarvis) — Apple requires the VoIP push topic (`apns-topic`)
  to be the app bundle ID for PushKit; a mismatched topic is rejected by APNs.
- Device token: DONE — app POSTs to /register on launch; bridge persists it server-side.
