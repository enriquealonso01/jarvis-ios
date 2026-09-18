# server/voice_gateway/gateway.py

This is a synced copy of the DEPLOYED `/opt/voice-gw/gateway.py` (voice
gateway, port 9150, systemd `jarvis-voice-gateway`) so the repo records what
runs in prod.

Deployed change 2026-09-18 (backlog #6): auth gate also accepts
`Authorization: Bearer <access token>` — the dashboard `basic` provider's
stateless HMAC token (kind=access, exp-checked), verified locally. Native
iOS clients connect their WebRTC view with the same Keychain token used for
the Control Center API. Cookie path for the PWA/orb is unchanged.

Deploy ritual (agent-side, safe to repeat):
1. Edit /opt/voice-gw/gateway.py (backup to /root/voice-gw-backup-*.py first)
2. `python3 -m py_compile /opt/voice-gw/gateway.py`  ← must pass
3. `systemctl restart jarvis-voice-gateway`
4. `curl -s http://127.0.0.1:9150/healthz` → `"ok": true`  ← must pass
5. `python3 scripts/probe_gateway_bearer_live.py` → 401 matrix must hold
6. `cp /opt/voice-gw/gateway.py /opt/voice-gw/last-known-good/gateway.py`
   and sync the copy into this directory.

Helper scripts live in `/scripts` (this repo): `patch_gateway_bearer.py`
(the exact change), `probe_gateway_auth.py`, `probe_gateway_bearer_live.py`.
