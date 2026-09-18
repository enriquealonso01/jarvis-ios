# PROGRESS

## 2026-09-18 07:05 UTC (build-loop run) — native WebRTC path verified END-TO-END (real client, live gateway)

- Previous runs had only auth-gate-verified the native offer (valid bearer →
  500). This run closed the last agent-verifiable gap: a REAL WebRTC client
  now exercises the exact iOS contract against the LIVE gateway and PASSES.
- New `scripts/probe_webrtc_native.py` (aiortc in isolated venv
  `/root/venvs/webrtc-probe`, aiortc+pyyaml — heavy native deps, deliberately
  not in the system interpreter): mints a dashboard Bearer, POSTs an SDP offer
  with `request_data {surface:"ios", reason}` to /voice-gw/api/offer, applies
  the answer, opens the ordered `app` data channel, sends literal "ping" at
  1 Hz, and asserts inbound audio track + gateway `hello` (thread + brain)
  arrive. Cleans up: /voice-gw/api/hangup on its throwaway session. First
  live run: offer 200 → answer → track + hello
  (brain openai:gpt-realtime-2.1-mini) → hangup ok → PASS.
- `verify_all.sh` now 6/6 steps: new step 6 runs the probe; sweep re-run
  exit 0 ALL GREEN (swift_sanity, bridge 15/15, gateway gate, live health,
  parity + crons, native WebRTC e2e). Probe skip-warns (non-fatal) if the
  venv is missing; setup one-liner documented in the script header.
- One real finding while building the probe: an offer without an explicit
  audio transceiver still gets a working data-channel session but no inbound
  track from aiortc's perspective — the iOS app is unaffected (it offers
  sendrecv audio like the web page), so no app/gateway change needed; the
  probe itself offers recvonly audio explicitly.
- Docs: ARCHITECTURE.md "Verifying the native path (no phone needed)".
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 06:45 UTC (build-loop run) — native-call data channel + call-reason context (the gap the audit found)

- Backlog 1-9 confirmed complete and sweep ALL GREEN again; audit of the live
  gateway against the app surfaced a real functional gap: the SmallWebRTC
  pipeline pushes ALL session UI (hello/state/transcript/metrics) over an
  "app" data channel and expects literal "ping" strings as liveness — the
  iOS WebRTCClient never created the channel, so native calls would have run
  mute-ish: no live state, no transcript, session looking dead.
- iOS: WebRTCClient now creates the ordered "app" channel post-answer, sends
  1 Hz "ping" (DispatchSourceTimer), implements RTCDataChannelDelegate, and
  exposes onAppMessage. CallManager maps hello/state/transcript into
  published sessionInfo/callState/lastTranscript; CallsView shows them.
- Gateway: /api/offer now reads request_data {surface, reason} — iOS offers
  are labeled surface "ios" (no longer mislabeled cc_pwa in metrics) and the
  call reason (from the VoIP push payload) is spoken naturally right after
  the greeting, so JARVIS-initiated calls explain why they rang.
- Deployed: py_compile gate → jarvis-voice-gateway restart → /healthz ok
  (realtime:true); bearer gate re-verified (valid 500 / bad 401); bridge
  probe 15/15 on throwaway; full verify_all.sh ALL GREEN (gateway mirror
  parity now includes this change). Backup: gateway.py.bak-ios-dc-*.
- Docs: GATEWAY.md + ARCHITECTURE.md document request_data + the data-
  channel contract ("required — don't remove").
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 06:25 UTC (build-loop run) — CRITICAL FIX: /register now accepts the app's Bearer

- Found a real mission-blocker during a code audit: `POST /register` was
  HMAC-only while the iOS app registers its APNs device token with the
  dashboard Bearer (the app cannot compute the agent HMAC). Every launch-time
  registration would 401 → DEVICE_TOKEN never persisted → **no VoIP push could
  ever ring the phone**, even after Enrique installs the p8. The Swift comment
  even said "bridge accepts dual auth after this commit" — that half never
  landed. Fixed: `/register` now uses `_auth_dual` (same ladder as /call).
- Probe extended to 15/15 (new: /register valid-bearer 200, bad-bearer 401,
  agent-HMAC still 200 + token overwrite). All PASS on a throwaway :9162.
- Deployed: py_compile gate → systemd restart jarvis-ios-bridge → live-verified
  on prod :9160 (bearer /register 200 registered:true; apns.env restored
  byte-identical afterward; /health ok; public /bridge/health 200). Full
  verify_all.sh sweep ALL GREEN (5/5, bridge active, gateway parity, crons armed).
- CallManager.swift comment corrected to match reality; swift_sanity OK.
- Committed + pushed f26c2c2 (main).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 (build-loop run) — maintenance sweep, ALL GREEN

- Backlog 1–9 complete; no drift found. Full `scripts/verify_all.sh` sweep:
  exit 0 — swift_sanity OK, bridge probe 12/12 PASS (throwaway :9162, prod
  untouched), gateway bearer gate correct (valid 500 / invalid+refresh 401),
  live health bridge :9160 ok + voice-gw :9150 realtime:true + public
  /bridge/health 200, prod parity both services active + gateway mirror
  identical, reminder crons armed (build-loop, loop-sunset, apple-setup-guide).
- NEEDS ENRIQUE (the only remaining ladder): Xcode build → TestFlight upload →
  APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).
## 2026-09-18 06:00 UTC (build-loop run) — verify_all.sh extended to prod parity + cron guard (5/5)

- Backlog 1–9 remain complete; nothing new actionable until the Enrique-gated
  ladder. This run hardened the sweep instead of idling: `verify_all.sh` now
  has step 5/5 —
  - both prod services `systemctl is-active` (jarvis-ios-bridge,
    jarvis-voice-gateway),
  - repo gateway mirror byte-identical to deployed /opt/voice-gw/gateway.py
    (drift now FAILS the sweep),
  - reminder crons armed check (build-loop, apple-setup-guide, loop-sunset —
    all present + enabled).
- Full sweep re-run: exit 0, ALL GREEN (5/5 steps; bridge 12/12, gateway gate,
  live health 200s, parity, crons).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 05:55 UTC (build-loop run) — maintenance sweep, all green

- Backlog 1–9 remain complete; nothing new actionable until the Enrique-gated
  ladder. No drift found.
- Full sweep via `scripts/verify_all.sh` (exit 0, ALL GREEN): swift_sanity OK;
  bridge probe **12/12 PASS** on a throwaway :9162 instance (prod untouched);
  gateway bearer gate passed (valid 500 / invalid-no-refresh 401); live health:
  bridge :9160 ok (apns_configured:false, scheduled:0), voice-gw :9150
  realtime:true, public /bridge/health 200.
- Repo clean, synced with origin/main (HEAD 75f3812).
- Reminder crons armed: jarvis-ios-apple-setup-guide (2026-09-19 13:00 UTC),
  jarvis-ios-loop-sunset (2026-09-19 23:00 UTC).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 05:44 UTC (build-loop run) — maintenance sweep + verify_all.sh one-command harness

- Backlog 1–9 remain complete; nothing new actionable until the Enrique-gated
  ladder. No drift found.
- **New: `scripts/verify_all.sh`** — the entire maintenance sweep (swift_sanity,
  bridge 12/12 bearer probe on a throwaway instance, gateway bearer-gate check,
  live health of bridge :9160 / gateway :9150 / public /bridge/health) is now
  ONE command with a proper exit code. Replaces the last three runs' repeated
  manual steps; future runs just execute it. Verified: exit 0, ALL GREEN.
  - Gateway-gate check asserts semantics, not the literal string "FAIL"
    (valid bearer 500 = gate passed; invalid/no-auth/refresh-kind all 401).
- Live verification this run: swift_sanity OK; bridge probe **12/12 PASS**
  (prod untouched); gateway bearer gate passed; bridge /health ok
  (apns_configured:false, scheduled:0); voice-gw /healthz realtime:true;
  public /bridge/health 200. Prod bridge runs straight from the repo working
  dir (systemd ExecStart), so code/prod parity is structural.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 05:35 UTC (build-loop run) — maintenance sweep, all green

- Backlog 1–9 complete; nothing new actionable until the Enrique-gated ladder.
  Full re-verification, no drift:
  - Repo clean, synced with origin/main (HEAD 6876a60). swift_sanity.py OK.
  - probe_call_bearer_live.py --spawn (fresh throwaway :9162, isolated state,
    self-cleaning): **12/12 PASS**; prod bridge untouched.
  - probe_gateway_bearer_live.py: valid bearer 500 (gate passed), invalid /
    no / refresh-kind bearer all 401.
  - Live health: bridge :9160 /health 200 (ok / apns_configured:false /
    scheduled:0); public /bridge/health 200; voice-gw :9150 /healthz 200.
  - gateway.py byte-identical to /opt/voice-gw/gateway.py.
  - Reminder crons armed: jarvis-ios-apple-setup-guide (2026-09-19 13:00 UTC),
    jarvis-ios-loop-sunset (2026-09-19 23:00 UTC).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 05:27 UTC (build-loop run) — maintenance sweep, all green

- Backlog 1-9 complete; nothing new actionable until the Enrique-gated ladder.
  Full re-verification, no drift:
  - Repo clean; swift_sanity.py OK.
  - probe_call_bearer_live.py --spawn (fresh throwaway, isolated state):
    **12/12 PASS**; prod bridge untouched.
  - probe_gateway_bearer_live.py: valid bearer 500 (gate passed), invalid /
    no / refresh-kind bearer all 401.
  - Live health: bridge :9160 /health 200 (ok / apns_configured:false /
    scheduled:0); public /bridge/health 200; voice-gw :9150 /healthz 200
    (realtime:true, openai_status ok).
  - gateway.py byte-identical to /opt/voice-gw/gateway.py.
  - Reminder crons confirmed armed: jarvis-ios-apple-setup-guide (9AM Miami
    Sat Sep 19) and jarvis-ios-loop-sunset (23:00 UTC Sep 19).
- Cleanup: removed a stray duplicate `# PROGRESS` H1 mid-file (introduced by
  an earlier prepend; file now has exactly one).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build ->
  TestFlight upload -> APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).


## 2026-09-19 05:18 UTC (build-loop run) — maintenance sweep, all green

- Backlog 1–9 remain complete; nothing new actionable server-side until the
  Enrique-gated ladder. Full re-verification, no drift:
  - Repo clean, synced with origin/main (HEAD 3e3ac0b). swift_sanity.py OK.
  - probe_call_bearer_live.py --spawn on a fresh throwaway (:9162, isolated
    state): **12/12 PASS**, instance + state cleaned up; prod bridge untouched.
  - Live health: bridge :9160 /health 200; public /bridge/health 200.
  - Reminder crons armed: jarvis-ios-apple-setup-guide 2026-09-19 13:00 UTC,
    jarvis-ios-loop-sunset 23:00 UTC.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-19 (build-blocker audit run) — first-Xcode-build hardening

- Full audit of all 12 Swift files for would-be Xcode build errors (Swift has
  never been compiled on this box; Enrique's first build is the gate). Found
  and fixed one certain breaker + several likely ones:
  - **ServerConfig declared twice** (Codable struct AND ObservableObject class
    in the same module) — instant "invalid redeclaration" build failure.
    Struct renamed to `ServerConfigValues` (AuthViews initializer updated).
  - `CXProvider.reportCall(with:endedAt:reason:)` doesn't exist → now
    `reportCall(with:endedAt:)` (CallManager.endActiveCall).
  - Local `URLRequest.init(url:method:)` shadowed an availability-gated
    Foundation initializer → replaced with a `URLRequest(postTo:)` factory.
  - Swift 6 strict-concurrency hardening: `@unchecked Sendable` on
    WebRTCClient/CCClient, `nonisolated(unsafe)` on the WebRTC factory +
    activeAudioSession statics, `@Sendable` token-provider closure,
    `@MainActor` AppDelegate (fixes UIApplicationDelegate conformance in
    Swift 6 mode).
  - `WorkHistory.messages` made Optional (decoder crash-guard; ChatsView
    already nil-coalesced).
- swift_sanity.py upgraded to catch this class of bug going forward:
  duplicate top-level type detection across all sources + hazard-pattern
  checks (nonexistent CXProvider API, shadowed URLRequest init). OK.
- probe_call_bearer_live.py now owns its listener: `--spawn` creates the
  throwaway uvicorn instance itself with atexit/signal-guaranteed cleanup
  (orphaned-instance incident class eliminated). Verified live: spawned on
  :9167, **12/12 PASS**, instance gone after exit; prod bridge untouched
  (/health ok, scheduled:0).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 (docs/BUILD.md, docs/FASTLANE.md). The compile
  error above would have blocked the very first build — now cleared.

## 2026-09-19 (maintenance run) — all green; probe hardened

- Full sweep, no drift:
  - Bridge prod :9160 /health 200 (ok / apns_configured:false / scheduled:0);
    public https://jarvis.enriquecodes.com/bridge/health 200; voice-gw :9150
    /healthz 200 (realtime:true). Repo clean, synced with origin/main.
  - swift_sanity.py OK; py_compile clean; gateway.py byte-identical to
    /opt/voice-gw/gateway.py; bridge service runs from the repo working tree
    (systemd app-dir), so no server drift by construction.
  - probe_gateway_bearer_live.py: valid bearer reaches SDP handler (500 = gate
    passed), invalid/no/refresh-kind all 401.
  - probe_call_bearer_live.py on a fresh throwaway (:9166, isolated state):
    **12/12 PASS**; instance killed after; prod state untouched.
- Hardened the probe itself: this run it first hit an ORPHANED stale test
  instance from a prior run (bind conflict + bare-HTML 500s), which crashed the
  probe with a JSONDecodeError instead of failing cleanly. `req()` now
  falls back to {"raw": ...} on non-JSON bodies, so a stale instance reads as
  FAIL with the raw body visible. Verified still 12/12 against a fresh
  instance. (Ops note: orphaned uvicorn test instances can linger when a run
  dies mid-probe — probes must always clean up their own listeners.)
- Backlog 1–9 remain complete. NEEDS ENRIQUE (unchanged, the only remaining
  ladder): Xcode build → TestFlight upload → APNs p8 install
  (docs/BUILD.md, docs/FASTLANE.md, docs/API.md "Pending").

## 2026-09-18 (late, run 2) — maintenance re-verification: all green, backlog remains complete

- Full sweep re-run, no drift anywhere:
  - Bridge prod :9160 /health 200 (ok / apns_configured:false / scheduled:0);
    public https://jarvis.enriquecodes.com/bridge/health 200; voice-gw :9150
    /healthz 200 (brain openai-realtime, realtime:true).
  - Bridge server copy: prod runs from the repo working tree, so no drift by
    construction; server/voice_gateway/gateway.py byte-identical to
    /opt/voice-gw/gateway.py.
  - probe_call_bearer_live.py on a fresh throwaway instance (:9164, isolated
    state dir): **12/12 PASS** (bearer/HMAC ladders on /call, /schedule,
    /schedule/list, /schedule/cancel, /secrets). Instance killed after; prod
    state untouched (apns.env still empty → apns_configured:false, scheduled:0).
  - probe_gateway_bearer_live.py: valid bearer reaches SDP handler (500 = gate
    passed), invalid/no/refresh-kind all 401.
  - scripts/swift_sanity.py: OK. git status clean, main synced with origin
    (Everything up-to-date), repo unchanged since 05a8e30.
- Nothing actionable without Enrique: the only remaining ladder is Xcode build
  → TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md,
  docs/API.md "Pending"). Reminder crons stay armed (apple-setup-guide
  2026-09-19 13:00 UTC, loop-sunset 23:00 UTC).
- NEEDS ENRIQUE (unchanged): the Xcode/TestFlight/APNs ladder.

## 2026-09-18 (late) — maintenance run: full re-verification, all green, nothing actionable

- Repo clean and synced with origin/main. Backlog 1–9 remain complete; no new
  server-side work possible (everything left is Enrique-gated).
- scripts/swift_sanity.py: OK. probe_call_bearer_live.py re-run on a fresh
  throwaway instance (:9163, isolated state dir): **12/12 PASS** (bearer/HMAC
  ladders on /call, /schedule, /schedule/list, /schedule/cancel, /secrets).
  Instance killed; /tmp state removed; prod state untouched (apns.env still
  empty → apns_configured:false, scheduled:0 as before).
- probe_gateway_bearer_live.py: valid bearer reaches SDP handler (500 = gate
  passed), invalid/no/refresh-kind all 401. Gateway file byte-identical to
  /opt/voice-gw/gateway.py (no drift).
- Live health: bridge :9160 /health 200; public
  https://jarvis.enriquecodes.com/bridge/health 200 (Caddy handle_path
  /bridge/* → :9160); voice-gw :9150 /healthz 200. py_compile gate clean.
- Reminder crons confirmed armed: jarvis-ios-apple-setup-guide
  2026-09-19 13:00 UTC, jarvis-ios-loop-sunset 23:00 UTC.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 04:25 UTC (run 2) — VoIP push-topic bug fix + ARCHITECTURE.md

- **Bug fixed before it cost a build**: `_send_voip` defaulted `apns-topic` to
  `com.enriquecodes.jarvis.voip`, but the app bundle ID (project.yml, BUILD.md)
  is `com.enriquecodes.jarvis`. Apple rejects VoIP pushes whose topic ≠ the
  app's bundle ID — the first real ring would have silently failed after the
  p8 install. Default corrected, docs/API.md pending-section corrected with an
  explicit topic==bundle-ID warning.
- Deployed live: py_compile gate → bridge restart → /health 200
  (ok/apns_configured:false/scheduled:0, prod state untouched) + public
  /bridge/health 200. Bridge still runs straight from the repo working tree.
- docs/ARCHITECTURE.md written (was referenced by README/backlog #6 but never
  existed): components map, Caddy routes, auth ladders, full call flow, and
  the Enrique-gated ladder in one page.
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8.
- Backlog 1–9 remain complete; nothing else actionable server-side.

## 2026-09-18 05:20 UTC — full-stack verification sweep — all green, awaiting Enrique

- Backlog 1–9 confirmed complete (git log + entries below). No drift: bridge
  service runs straight from the repo (server/push_bridge/main.py is the
  deployed code; WorkingDirectory=server/push_bridge), and
  server/voice_gateway/gateway.py is byte-identical to /opt/voice-gw/gateway.py.
- Live health: bridge :9160 /health 200, public /bridge/health 200, voice-gw
  :9150 /healthz 200.
- Re-ran probe_call_bearer_live.py against a fresh throwaway instance (:9162,
  real secret, isolated state): 12/12 PASS (bearer/HMAC auth ladders on
  /call, /schedule, /schedule/list, /schedule/cancel, /secrets). Instance
  killed after; prod state verified untouched (apns.env empty, scheduled_calls
  [], secrets {}) — so the bridge still shows apns_configured:false and the
  queue path only, exactly as before.
- probe_gateway_bearer_live.py re-run: valid bearer reaches the SDP handler
  (500 = no SDP sent, gate passed), invalid/no/refresh-kind all 401.
- scripts/swift_sanity.py: OK (structure, assets, project.yml).
- Reminder coverage confirmed: cron jarvis-ios-apple-setup-guide fires
  2026-09-19 13:00 UTC; jarvis-ios-loop-sunset 23:00 UTC (backlog #8's
  upload-reminder requirement is covered by these).
- NEEDS ENRIQUE (unchanged, the whole remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md,
  docs/API.md "Pending"). Nothing else actionable server-side.

## 2026-09-18 04:10 UTC — backlog #9: polish (app icon, launch screen, Settings, haptics, error/empty states) — DONE, backlog complete

- App icon: generated 1024×1024 arc-reactor mark (dark #0A0B0F, gold rings +
  12 ticks, glowing core) via `scripts/gen_app_icon.py` (Pillow, reproducible);
  single-size AppIcon.appiconset, vision-verified clean (no clipping).
  AccentColor colorset = JARVIS gold, wired via
  ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME.
- Launch screen: plist UILaunchScreen dict (LaunchBackground color +
  LaunchReactor image) — dark from first frame, no storyboard, no white flash.
- Settings rebuilt: server URLs, one-tap connection test (pings
  /api/control/vitals), manual access-token entry (paste → Keychain via
  AuthStore.applyManualToken, debug/minted-session fallback), copy-token,
  Face ID lock toggle for Secrets, sign out.
- Secrets tab: optional Face ID/biometrics gate (LocalAuthentication, degrades
  to open when no passcode is set). All haptics centralized in Haptics.swift;
  SecretsView/CallManager/CallsView converted.
- Error/empty states: Home + Chats error cards now have Retry buttons; Chats
  empty state upgraded. `scripts/swift_sanity.py` added (brace balance, required
  symbols, asset-JSON validity, project.yml wiring) — passing.
- docs/ICON.md: icon/launch-screen spec + regeneration recipe.
- NEEDS ENRIQUE (unchanged): first Xcode build/upload — xcodegen picks up the
  new Assets.xcassets automatically (docs/BUILD.md). Swift still not compiled on
  this box; verified structurally only.
- Backlog items 1–9 are now all landed. Remaining mission work = the
  Enrique-gated ladder: Xcode build → TestFlight upload → APNs p8 install
  (docs/BUILD.md, docs/FASTLANE.md, docs/API.md "Pending" section).

## 2026-09-18 04:55 UTC — backlog #8: voice call_enrique + schedule_call tools — LIVE

- Forged two voice tools via jarvis-voice-forge, both validated + enabled:
  - `call_enrique(reason)` — HMAC-signs and POSTs to bridge /call; returns
    call_id + spoken line. Live-verified against :9160 (pushed:false while APNs
    p8 is pending — queue path works).
  - `schedule_call(reason, at_iso)` — validates/parses ISO-8601, normalizes to
    UTC, POSTs to bridge /schedule; live-verified (entry created then scrubbed
    via /schedule/cancel-all; health shows scheduled:0).
- Shared secret read from /opt/jarvis-ios-bridge/shared_secret (root-only);
  no secret material in the tool files.
- Scheduled-call cron support ('call me at 10am about X') is now possible from
  any voice/WhatsApp turn via these tools; WhatsApp-side recipe stays in
  docs/API.md (unchanged).
- NEEDS ENRIQUE: nothing new — APNs p8 still pending (both tools queue fine
  without it; real rings start once the key is installed).
- Next: backlog #9 polish (icon spec, launch screen, Settings), then re-verify
  full ladder when Enrique does the Xcode build + TestFlight upload.

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
