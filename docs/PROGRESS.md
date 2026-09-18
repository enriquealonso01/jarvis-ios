# PROGRESS

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
