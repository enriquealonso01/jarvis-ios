# JARVIS iOS — TestFlight Control Center + Native Calls

Enrique's native iPhone connection to the JARVIS system. Never goes to the App
Store: distributed via TestFlight internal testing only.

## Mission
1. **Control Center, iOS-level.** Native SwiftUI app with iOS-26-style Liquid
   Glass effects (`.glassEffect` modifiers), matching the feel of the existing
   mobile Control Center web view but better: real navigation, haptics, dark
   always. Home = CC summary (status, crons, LLM usage, current work, alerts).
   Per-project chats: open a chat scoped to a project, read history, send
   messages (→ dashboard agent). Secrets: add/update named secrets (stored
   server-side via the gateway's secret scope, never in the app or repo).
2. **Calls.** JARVIS (WhatsApp or voice) can place a call TO Enrique's phone
   through this app: server → APNs VoIP push → CallKit full-screen UI →
   WebRTC audio to the voice gateway. Phone may be locked; app may be killed.
   Goal state: "JARVIS, call me at 10am about X" → scheduled cron → at 10am
   the app rings with context attached.
3. **Agent-changeable.** JARVIS agents (this repo's loop agent, WhatsApp JARVIS,
   voice JARVIS) can modify app code and server config freely. Enrique's only
   manual step: open Xcode on the Mac, bump, upload to TestFlight. Everything
   else (server push bridge, gateway changes, docs) deploys automatically.

## Layout
- `ios/` — Xcode project (SwiftUI, iOS 26 SDK, Liquid Glass)
- `server/push_bridge/` — small FastAPI service: issues APNs VoIP pushes on
  demand (`POST /call`), reads gateway state. Runs on the JARVIS box under systemd.
- `docs/` — BUILD.md (Enrique's Xcode ritual), ARCHITECTURE.md, API.md
- `scripts/` — fastlane helpers, deployment scripts, loop-agent state files

## Rules for agents working here
- Enrique's Apple Team ID / bundle IDs live in docs/BUILD.md placeholders —
  never commit real signing material; there should be none on this box.
- APNs auth key (.p8) lives in the gateway secret scope only, never in git.
- Every work session: `docs/PROGRESS.md` gets a dated entry at the top.
- Conventional commits, author `Enrique Alonso <exa8981@gmail.com>`.
- Never break the running gateway/dashboard while editing; new services only.
