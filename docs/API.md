# Push Bridge API (127.0.0.1:9160, systemd `jarvis-ios-bridge`)

All POSTs require header `x-bridge-sig`: HMAC-SHA256 of the exact raw request body,
keyed by the shared secret in /opt/jarvis-ios-bridge/shared_secret (root-only).

- `POST /call` `{reason, scheduled_by?}` -> `{call_id, pushed}`. Fires VoIP push now.
  `pushed:false` = APNs p8 not yet configured (bridge still queues/logs).
- `POST /schedule` `{at_iso (ISO-8601, prefer +00:00), reason, scheduled_by?}` -> `{call_id, at}`.
  Internal scheduler fires when due (20s tick).
- `GET /health` -> `{ok, apns_configured, scheduled}`.

## Calling Enrique (for WhatsApp/voice JARVIS tools)
1. `secret=$(cat /opt/jarvis-ios-bridge/shared_secret)`
2. `body='{"reason":"Call about X","scheduled_by":"whatsapp-jarvis"}'`
3. `sig=$(printf %s "$body" | openssl dgst -sha256 -hmac "$secret" -hex | cut -d' ' -f2)`
4. `curl -s -X POST http://127.0.0.1:9160/call -H "Content-Type: application/json" -H "x-bridge-sig: $sig" -d "$body"`

## Pending until Enrique does his part
- APNs: create .p8 key in App Store Connect (Keys tab), download, then JARVIS stores it at
  /opt/jarvis-ios-bridge/apns.key (root 600) and writes /opt/jarvis-ios-bridge/apns.env with
  APNS_KEY_ID, APNS_TEAM_ID, APNS_P8_PATH, APNS_BUNDLE_ID=com.enriquecodes.jarvis.voip, APNS_SANDBOX=0.
- Device token: app registers on first launch, POSTs it to /register (TODO endpoint) or manual write.
