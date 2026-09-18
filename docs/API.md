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
- `GET /health` -> `{ok, apns_configured, device_registered, last_push_error,
  scheduled}`.
  `device_registered` = the phone has completed POST /register (boolean
  presence signal only — the token itself is never exposed here).
  `last_push_error` records every APNs non-200 (`"<code> <reason> at <ts>"`)
  AND transport failures (`"transport <ErrorName> at <ts>"` — h2 handshake,
  timeout, connection reset are caught inside `_send_voip` and never escape
  into POST /call; empty string = healthy).

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

### One-liner (backlog #8, added 2026-09-18): `scripts/call_enrique.py`

Wraps the whole recipe — reads the secret, signs, calls the bridge:

```
python3 scripts/call_enrique.py call     --reason "Market update" --by "cron:jobname"
python3 scripts/call_enrique.py schedule --at 2026-09-19T14:00:00+00:00 --reason "10am Miami chat"
python3 scripts/call_enrique.py list
python3 scripts/call_enrique.py cancel --id ab12cd34      # or omit --id to cancel all
```

(`pushed:false` on `call` = no registered iPhone yet; check `GET /health`.)

### Voice JARVIS: `call_enrique` tool (LIVE 2026-09-18)

The voice brain (Pipecat tool layer, /opt/voice-gw/brain.py — repo mirror
`server/voice_gateway/brain.py`) exposes a `call_enrique` function tool:
`action=now|schedule|list|cancel` (+ `reason`, `at_iso`, `call_id`). During a
call Enrique can say "give me a ring", "call me at 10am about X" and the brain
signs the bridge request itself (same HMAC contract). Proven end-to-end
2026-09-18: schedule→list→cancel and now→pushed:false-with-guidance.

### Raw curl recipe

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
- APNs KEY CAPABILITY (found 2026-09-18 22:20): the installed key (kid 2PMV4SF2LS)
  works for the App Store Connect API but is REJECTED by APNs itself — both hosts
  answer `403 InvalidProviderToken` to a correctly signed provider token
  (`scripts/probe_apns_delivery.py`). The key was created without the "Apple Push
  Notifications service (APNs)" capability. Fix (Enrique): developer.apple.com →
  Certificates, Identifiers & Profiles → Keys → create a new key WITH APNs checked
  → download .p8, then tell JARVIS — install is agent-side after that, ONE
  COMMAND: `python3 scripts/swap_apns_key.py --p8 <file> --key-id <NEWKID>`.
  The script refuses to stage anything until the candidate key passes three
  gates (PEM format, ES256 sign, Apple's own `400 BadDeviceToken` verdict on a
  dummy token — same shape as the probe), then installs 0600 + updates
  apns.env atomically (rollback on failure). No bridge restart needed
  (`_send_voip` re-reads env per push); afterwards `scripts/probe_apns_delivery.py`
  must print `400 BadDeviceToken` on the live paths — the probe runs TWO legs
  per verdict (curl AND the bridge's exact httpx+h2 production client,
  "BRIDGE-STACK"), so a bridge-transport regression can never hide behind a
  curl-only green. Until then VoIP pushes
  CANNOT be delivered: /call answers pushed:false with
  `[bridge] APNs push REJECTED` in the journal. verify_all step 1b prints the
  probe verdict on every run.
- Device token: DONE — app POSTs to /register on launch; bridge persists it server-side.
