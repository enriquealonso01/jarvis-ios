# PROGRESS

## 2026-09-18 04:25 UTC — backlog #7: fastlane Fastfile + one-command upload.sh

- `ios/fastlane/Fastfile`: `testflight` (xcodegen → archive → upload, skips
  processing wait), `build_only`, `compile_check` (no-signing build for
  sanity). `scripts/upload.sh` wraps both (syntax-checked; Fastfile lanes
  verified present). `docs/FASTLANE.md`: one-time App Store Connect API-key
  auth setup + every-upload ritual for Enrique's Mac.
- NEEDS ENRIQUE: fastlane install + API key on his Mac (docs/FASTLANE.md);
  signed upload is Mac-only by design.
- Next: backlog #8 `call_enrique` tool for WhatsApp/voice JARVIS + scheduled-
  call cron support + upload reminder.

## 2026-09-18 04:05 UTC — backlog #4: CallKit + PushKit + WebRTC client (app) + bearer-authed calling endpoints — LIVE

- Bridge: `/call`, `/schedule`, `/schedule/cancel`, `/schedule/list` now accept
  the app's dashboard Bearer token (same dual-auth ladder as `/secrets`).
  Probe `scripts/probe_call_bearer_live.py`: 12/12 (valid/invalid/refresh/no-auth
  ladders per endpoint, HMAC agent path intact, bearer-created schedule entry
  listed + cancelled). Live-verified on :9160 after restart; /health + public
  /bridge/health 200. VoIP push payload now carries `gateway_ws: "/voice-gw"`
  (both /call and the scheduler fire path) matching docs/GATEWAY.md.
- iOS: CallManager (PushKit PKPushRegistry + CXProvider/CXCallController;
  reportNewIncomingCall inside the VoIP callback per the iOS hard requirement;
  CXAnswerCallAction drives the WebRTC connect; audio session activation hooks),
  WebRTCClient (Google WebRTC STS via SPM `stasel/WebRTC`; audio-only offer →
  POST {sdp,type} to {voice-gw}/api/offer with Bearer → set answer; /api/say +
  /api/hangup controls; STUN from gateway recipe). AuthStore.validAccessToken()
  refreshes-when-expiring for the offer call. AppDelegate registers PushKit at
  launch and re-POSTs the APNs token to /register (Bearer) on token rotation.
  CallsView rewritten: real /call button (Bearer), live call state, scheduled
  list + cancel — all against the live bridge.
- project.yml: WebRTC package dependency; BUILD.md documents the ~400MB first
  SPM resolve.
- NEEDS ENRIQUE: first Xcode build with the new WebRTC package (xcodegen →
  open → resolve packages → sign → run). Swift not compiled on this box.
- Next: fastlane (backlog #7) or the WhatsApp/voice `call_enrique` tool
  (backlog #8 — server-side /call recipe already in docs/API.md).

## 2026-09-18 03:20 UTC — backlog #3: Secrets (server store + iOS UI) LIVE

- Named-secret store deployed on the push bridge (`/secrets`, `/secrets/set`,
  `/secrets/delete`): values persist in /opt/jarvis-ios-bridge/secrets.json
  (0600) and are never returned by any endpoint — only names + masked previews
  (first 2 chars, length, updated_by/at). Note: no HTTP "gateway secret scope"
  endpoint exists in Hermes; the bridge store is the secret scope surface for
  this project, so the backlog item landed there.
- Dual auth: x-bridge-sig HMAC (agents) OR `Authorization: Bearer` dashboard
  access token (iOS app) — same gateway-identical verify ladder (sig +
  kind=access + exp, local verify). 18/18 functional checks passed on a
  throwaway instance (:9161): both auth paths, expired/refresh-kind/bad-token
  401s, 422 validation, upsert created flag, delete, no value leak in any
  response. Live round-trip verified on :9160 after restart, probe entry scrubbed.
- Caddy: `/bridge/*` route added (handle_path → 127.0.0.1:9160, prefix
  stripped; backup /etc/caddy/Caddyfile.bak-iosbridge-20260918). Verified:
  public `/bridge/health` 200, `/bridge/secrets` 401 without creds, 200 with
  bearer; /voice-gw untouched.
- iOS: SecretsView fully wired (list with masked metadata, add/update with
  SecureField, swipe-free delete via confirmation dialog, haptics, pull-to-
  refresh). CCClient.urlFor() now passes absolute bridge URLs through (Bearer
  auth + auto-refresh reused). ServerConfig defaults fixed: bridge =
  https://jarvis.enriquecodes.com/bridge, voice gateway = jarvis origin
  (offer path /voice-gw/api/offer) — the old voice.enriquecodes.com /
  bridge.enriquecodes.com hosts don't exist.
- docs/API.md: secrets endpoints + agent recipe.
- NEEDS ENRIQUE (unchanged): first Xcode build/upload (see docs/BUILD.md).
- Next: backlog #4 CallKit + PushKit + WebRTC client in the app (server side
  fully unblocked: bearer offer endpoint + VoIP push payload contract ready).

## 2026-09-18 03:00 UTC — backlog #6: gateway native-client WebRTC access LIVE

- /opt/voice-gw/gateway.py auth gate now accepts `Authorization: Bearer <access
  token>` (the dashboard `basic` provider's stateless HMAC token — same one the
  app already holds in Keychain from the RFC 8252 flow). Verified locally against
  the signing secret the gateway already loads: sig + kind=access + exp. Cookie
  path (CC orb/PWA) untouched.
- Backup before edit: /root/voice-gw-backup-20260918-025349.py. py_compile gate
  passed; service restarted; /healthz ok (brain openai-realtime); last-known-good
  snapshot updated post-verify.
- Live auth matrix verified (scripts/probe_gateway_bearer_live.py): valid bearer
  passes gate → reaches SDP handler (500 only because probe sends no SDP — that
  is a handler-level error, proving 401 is gone); invalid/no/refresh-kind → 401.
- docs/GATEWAY.md written: offer/answer recipe for the iOS app (same endpoint as
  the orb), say/hangup controls, VoIP push payload contract, refresh-on-401 note.
- server/voice_gateway/gateway.py = synced deployed copy for traceability.
- Next: backlog #3 Secrets tab → server-side storage; #4 CallKit/PushKit/WebRTC
  client in the app (now unblocked server-side).

## 2026-09-18 02:35 UTC — bridge /register + scheduled-call list/cancel live (backlog #5)
- POST /register: app sends APNs device_token on launch; bridge persists DEVICE_TOKEN=
  into /opt/jarvis-ios-bridge/apns.env (0600) via _save_env_key; auto-injected into every
  /call push and snapshotted into each /schedule entry. Rejects short tokens (422), bad
  sigs (401).
- GET /schedule/list (HMAC over empty body) and POST /schedule/cancel ({call_id} cancels
  one, {} cancels all). Scheduler loop fixed to read the schedule once per tick.
- Tested 15/15 functional checks against a throwaway instance (:9161, isolated state dir):
  register good/bad-sig/short-token, 0600 perms, schedule x2, list, cancel one/all,
  /call falls back cleanly with no APNs. Test instance + temp state killed afterwards.
- Live service restarted (py_compile gate passed); /health verified ok after restart;
  live /register round-trip verified, then test token scrubbed from apns.env.
- docs/API.md updated with all three endpoints.
- Next: backlog #3 Secrets tab -> gateway secret-scope endpoint wiring, #4 CallKit/
  PushKit/WebRTC in the app, then #6 gateway native-client offer/answer.

## 2026-09-18 02:20 UTC — iOS app shell committed + GitHub repo live (backlog #1)
- GitHub repo created (private) and pushed: github.com/enriquealonso01/jarvis-ios (main @ 515b445).
- ios/JarvisApp: SwiftUI sources for the full shell — App entry, RootTabView
  (Home / Chats / Secrets / Calls), Liquid-Glass card styling (iOS 26
  glassEffect path documented; material fallback for <26), dark-first.
- Home: real CC data — /api/control/vitals, /zai_usage, /automations,
  /activity; card shapes match hermes_cli/web_routers/control_center.py.
- Chats: project/thread list from /api/control/dispatch/board; per-thread
  history via /api/control/work/{id}/history; send via /api/control/work/{id}/chat.
- Auth: RFC 8252 native PKCE flow against the dashboard (basic password
  provider): /auth/native/authorize → /auth/password-login (ephemeral cookie
  jar) → /auth/native/token → Bearer tokens in Keychain; refresh via
  /auth/native/refresh. Verified server-side with a minted session token
  against vitals/overview/spend/zai_usage/automations/activity/dispatch.
- Secrets/Calls tabs are visible shells wired to their backlog items (#3, #4).
- ios/project.yml (XcodeGen) + docs/BUILD.md updated: Enrique runs
  `xcodegen` then opens the project (no Swift toolchain on this box).
- NEEDS ENRIQUE: first Xcode build (`xcodegen`, open, sign, run) — nothing
  compiles on this box; Swift syntax verified structurally only.
- Next: backlog #3 gateway secret-scope UI, #4 CallKit/PushKit/WebRTC,
  #5 bridge /register endpoint.

## 2026-09-18 01:46 UTC — bootstrap (main JARVIS)
- Repo created at /root/projects/jarvis-ios (git, main branch)
- README mission + agent rules written
- Next: delegate loop agent 5-min cycles until 2026-09-19 19:00 UTC+? (Enrique said "tomorrow at 7PM" = Sep 19 19:00 Miami = 23:00 UTC; loop until then)
- Backlog v1: SwiftUI app shell (CC view, chats, secrets, call log), CallKit+PushKit,
  WebRTC client vs voice gateway, push_bridge FastAPI + systemd, fastlane, WhatsApp/voice
  "call me" tooling, scheduled calls cron
