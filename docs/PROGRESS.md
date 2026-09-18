# PROGRESS

## 2026-09-18 02:1x UTC — iOS app shell (backlog #1)
- ios/JarvisApp: SwiftUI sources for the full shell — App entry, RootTabView
  (Home / Chats / Secrets / Calls), Liquid-Glass card styling (iOS 26
  glassEffect path documented; material fallback for <26), dark-first.
- Home: real CC data — /api/control/vitals, /zai_usage, /automations,
  /activity; card shapes match hermes_cli/web_routers/control_center.py.
- Chats: project/thread list from /api/control/dispatch/board; per-thread
  history via /api/control/work/{id}/history; send via /api/control/work/
  {id}/chat.
- Auth: RFC 8252 native PKCE flow against the dashboard (basic password
  provider): /auth/native/authorize → /auth/password-login (ephemeral cookie
  jar) → /auth/native/token → Bearer tokens in Keychain; refresh via
  /auth/native/refresh. Verified server-side with a minted session token
  against vitals/overview/spend/zai_usage/automations/activity/dispatch.
- Secrets/Calls tabs are visible shells wired to their backlog items (#3, #4).
- ios/project.yml (XcodeGen) + docs/BUILD.md updated: Enrique runs
  `xcodegen` then opens the project (no Swift toolchain on this box —
  NEEDS ENRIQUE for first Xcode build/testflight upload).
- Next: backlog #2 polish is largely done inside this increment; #3 gateway
  secret-scope UI, #4 CallKit/PushKit/WebRTC, #5 bridge /register endpoint.

## 2026-09-18 01:46 UTC — bootstrap (main JARVIS)
- Repo created at /root/projects/jarvis-ios (git, main branch)
- README mission + agent rules written
- Next: delegate loop agent 5-min cycles until 2026-09-19 19:00 UTC+? (Enrique said "tomorrow at 7PM" = Sep 19 19:00 Miami = 23:00 UTC; loop until then)
- Backlog v1: SwiftUI app shell (CC view, chats, secrets, call log), CallKit+PushKit,
  WebRTC client vs voice gateway, push_bridge FastAPI + systemd, fastlane, WhatsApp/voice
  "call me" tooling, scheduled calls cron
