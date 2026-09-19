# JARVIS-iOS Backlog — CLOSED 2026-09-19

All nine launch-backlog items are DONE and verified. New work enters as fresh,
independently-motivated increments (bug reports, Enrique requests, contract
probe findings) — not as extensions of this list. Future loop runs should read
this first, then run `scripts/verify_all.sh`, then maintain.

| # | Item | Status | Evidence |
|---|------|--------|----------|
| 1 | App shell: SwiftUI app, CC home cards, Liquid Glass, Home/Chats/Secrets/Calls tabs | DONE | `ios/JarvisApp/JarvisApp.swift` (RootTabView), `HomeView.swift`; ships in every build (1→30); `swift_sanity.py` |
| 2 | Chats: per-project threads via dashboard API | DONE | `ChatsView.swift` + `CCClient.swift`; contracts live-proven by `check_cc_contract.py` (1e) + `check_chat_contract.py` (1g) |
| 3 | Secrets: server-side named secrets, masked, never stored client-side | DONE | `SecretsView.swift`; `check_bridge_contract.py` (1f) proves all 8 bridge routes → Swift models |
| 4 | Calls: CallKit + PushKit + VoIP push + WebRTC to gateway, call log, ring-me | DONE | `CallManager.swift`, `WebRTCClient.swift`, `CallsView.swift`; `check_push_payload_contract.py` (1h) + native WebRTC e2e (verify_all step 6, aiortc vs live gateway) |
| 5 | Bridge: /register device-token endpoint, scheduled-call list/cancel | DONE | `server/push_bridge/main.py` (`/register`, `/schedule/list`, `/schedule/cancel`); pinned in docs/API.md |
| 6 | Gateway: WebRTC offer/answer exposed to native clients | DONE | same session.py pipeline as the orb; documented in docs/GATEWAY.md + docs/ARCHITECTURE.md; `probe_webrtc_native.py` |
| 7 | fastlane: one-command TestFlight build+upload | DONE | `ios/fastlane/Fastfile` + `scripts/upload.sh` (+`--build-only`); docs/FASTLANE.md; CI path = ios-release.yml (tag `ios-v*`) |
| 8 | Integration: call_enrique agent tool + scheduled-call cron support | DONE | `scripts/call_enrique.py` (call/schedule/list/cancel); voice tools `call_enrique` + `schedule_call` live in /root/.hermes/jarvis/voice_tools/; scheduler robustness: `check_scheduler_robust.py` |
| 9 | Polish: icon, launch screen, error/empty states, haptics, Settings | DONE | `scripts/gen_app_icon.py` + AppIcon 1024 + AccentColor + UILaunchScreen (docs/ICON.md); load-failure-vs-empty states in Secrets/Calls views; `Haptics.swift`; SettingsView in `AuthViews.swift` |

## Standing state (post-backlog)
- **Shipped:** build 30 (tag ios-v28) VALID + IN_BETA_TESTING — carries the
  TEXT-ping keepalive fix. Provable any time: `scripts/ship_gate.py`.
- **Maintenance surface (every run):** `scripts/verify_all.sh` (doc contracts,
  swift sanity, APNs probe, push counters, 1d–1h checkers, parity, sentinel,
  WebRTC e2e, ship gate), device-watch crons, sunset/wrap-up one-shots.
- **NEEDS ENRIQUE (the only blockers left, all phone/web-side):**
  1. APNs-capable .p8 key → `scripts/swap_apns_key.py` installs it.
  2. Phone: open TestFlight, install the HIGHEST build, sign in once
     (`device_registered` must flip true).
  3. Re-register his personal Signal account (DM bounces UNREGISTERED_FAILURE
     since 2026-09-19; groups still deliver).
- **Ring-path endgame:** once (1)+(2) land, the device-watch fires a real
  verification call via `call_enrique.py` and declares MISSION COMPLETE only
  if Apple accepts it (fail-closed URGENT otherwise).
