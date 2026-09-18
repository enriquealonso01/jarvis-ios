# PROGRESS

## 2026-09-18 13:35 UTC (build-loop run) — ChatsView new-task slug now mirrors the server's slug rule exactly

- Contract-audit of the Chats "New project task" flow found ONE real defect:
  **the app's slug-ifier didn't match the server's.** Dashboard
  `control_project_task` builds `project-<slug>` with
  `re.sub(r"[^A-Za-z0-9_-]", "", project)[:48]` (keeps hyphens/underscores);
  the app used `CharacterSet.alphanumerics.inverted`, which DROPS them —
  "jarvis-ios" produced `project-jarvisios` client-side while the server
  created `project-jarvis-ios`. The optimistic row inserted the wrong id and
  every subsequent chat POST/history GET in that thread hit a conversation
  that doesn't exist server-side (silent divergent threads for any project
  whose name contains a hyphen — which is most of Enrique's).
- Fixed in ChatsView.startTask: explicit allowed-set filter
  `[A-Za-z0-9_-]` + 48-char truncate + "adhoc" fallback, byte-for-byte the
  server rule; comment documents why.
- swift_sanity pin swapped to require the allowed-set form (the old pin
  actually pinned the BUGGY alphanumerics.inverted line — a revert to it now
  fails the sweep).
- Parity harness run (8 tricky inputs incl. "jarvis-ios", "Krendora_IG",
  "---", 50+ char truncation): server slug == swift slug on all — PASS.
- swift_sanity: exit 0 with the new pin.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 13:04 UTC (build-loop run) — CallsView scheduled list no longer wipes on outage (last lie of this class); sweep all green

- Defect-hunt pass (all 9 backlog items built; remaining runs are audit/hardening)
  found ONE real defect: **`CallsView.loadScheduled()` still did
  `catch { scheduled = [] }`** — a transient bridge outage rendered the lie
  "Nothing scheduled." on the Calls tab, the exact bug class already fixed in
  SecretsView (13:20 run) but missed here. Fixed: failed fetch keeps the
  last-known-good list + shows "Can't reach the bridge — scheduled calls NOT
  loaded."; the empty state only renders when the fetch succeeded and the
  schedule is genuinely empty.
- swift_sanity required-guard pins added for CallsView (loadFailed flag,
  empty-gate condition, error label) — a revert to the bare `scheduled = []`
  now fails the sweep like the SecretsView pins do.
- Full verify_all: exit 0 ALL GREEN (doc pins 6/6, swift_sanity incl. new
  pins, drop-detection + scheduler pins, bridge probe 16/16, gateway bearer
  gate, live health, prod parity + 3 crons, native WebRTC e2e PASS).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md;
  apple-setup guide cron fires 9AM Miami Sep 19).

## 2026-09-18 13:45 UTC (build-loop run) — docs/API.md caught documenting the leaked /schedule/list shape; doc-contract pins added; sweep all green

- Live contract re-audit (full end-to-end against prod with a minted dashboard
  Bearer: vitals/overview/zai_usage/automations/activity/attention/dispatch
  board, work chat + history, project/task, bridge /schedule/list + /health)
  found ONE real drift — **docs/API.md still showed the `/schedule/list`
  response WITH the `device_token` field** after 60c121e stripped it from the
  code. Anyone building against the doc would expect (and test for) the very
  leak the fix removed. API.md now documents the stripped shape + the
  strip rationale; ARCHITECTURE.md scheduler line clarified too.
- Everything else verified zero-drift: CC models match live payloads
  (vitals/overview/zai/automations/activity/attention/board shapes confirmed
  byte-for-byte against responses), work chat {reply} + history {available,
  messages[role,ts,text,tool_name?]} correct, project/task slug contract
  correct, secrets/schedule/cancel/register endpoints match their docs.
- New `scripts/check_doc_contracts.py` (step 0 of verify_all.sh): pins the
  documented /schedule/list shape to the code's filter, the gateway_ws payload
  field, and the BUILD.md push-capability promise — doc drift now fails the
  sweep instead of waiting for a human to notice.
- Full verify_all: exit 0 ALL GREEN (doc pins 6/6, swift_sanity, scheduler
  pins, bridge probe 16/16, gateway bearer gate, live health, parity + crons,
  native WebRTC e2e PASS).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md;
  apple-setup guide cron fires 9AM Miami Sep 19).

## 2026-09-18 13:20 UTC (build-loop run) — /schedule/list no longer leaks the APNs device token; SecretsView outage no longer lies "empty"; sweep all green

- Audit found TWO real defects (bridge runs from the repo dir, so repo = prod):
- **`GET /schedule/list` returned raw schedule entries — including the
  snapshotted APNs `device_token`** (and the internal `failures` counter)
  to every authed caller. The device token is a push-delivery secret; only
  the scheduler fire path needs it. Fixed: entries are now stripped of
  `device_token`/`failures` in the response. Probe pin added
  ("/schedule/list strips device_token + failures") — 16/16 on a throwaway
  instance; live prod check shows the scheduled entry WITHOUT the token.
- **SecretsView wiped the list on any transient fetch failure**
  (`catch { secrets = [] }`): a bridge blip rendered the lie "No secrets
  stored. Values live server-side only." Fixed: load failure now keeps the
  last-known-good list and shows "Can't reach the bridge — secrets NOT
  loaded."; the empty-state only renders when the fetch SUCCEEDED and
  returned nothing. swift_sanity required-guard pins both.
- Deploy: py_compile pass → jarvis-ios-bridge restart → /health ok
  (scheduled:1 preserved) → public /bridge/health 200 → live
  /schedule/list verified stripped. Full scripts/verify_all.sh: exit 0 ALL
  GREEN (swift_sanity incl. new pins, scheduler pins 7/7, bridge probe
  16/16, gateway bearer gate, live health, prod parity + 3 crons, native
  WebRTC e2e PASS vs live gateway).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md,
  apple-setup guide cron fires 9AM Miami tomorrow).

## 2026-09-18 12:55 UTC (build-loop run) — Push Notifications entitlement wired (first-build VoIP blocker); sweep all green

- Audit pivot: every Swift file has been line-by-line hardened across prior
  runs, so this run audited the FIRST-BUILD ENVIRONMENT instead — the things
  that fail only when Enrique opens Xcode. Found one real mission-blocker:
- **No `aps-environment` entitlement anywhere in the project** —
  project.yml set `UIBackgroundModes: voip` but never `CODE_SIGN_ENTITLEMENTS`.
  With automatic signing that produces a provisioning profile with NO push
  capability: APNs rejects every VoIP push (bad device token / topic
  mismatch class), so "JARVIS calls this phone" — the mission centerpiece —
  would silently never ring even after Enrique installs the .p8 and the
  bridge reports apns_configured:true. The failure would only surface as
  "no ring, no error" on device.
- Fix: `ios/JarvisApp/JarvisApp.entitlements` (aps-environment=development;
  TestFlight/App Store archives are rewritten to production automatically),
  wired via `CODE_SIGN_ENTITLEMENTS` in project.yml. Plist + YAML parse
  verified on-box.
- SPM pin verified live: stasel/WebRTC tag **130.0.0 exists upstream**
  (checked the GitHub tags API) — Enrique's first package resolve will not
  fail on a missing tag. `from: 130.0.0` may float upward but 130.0.0 is a
  valid floor.
- swift_sanity: new pins — entitlement file present + `aps-environment`
  inside it, `CODE_SIGN_ENTITLEMENTS` wiring in project.yml, SPM URL pin —
  so none can regress silently.
- BUILD.md: first-build section now tells Enrique Signing & Capabilities
  must show "Push Notifications" after he picks his team (and how to add it
  if Xcode doesn't auto-promote).
- Full scripts/verify_all.sh: exit 0 ALL GREEN (swift_sanity incl. new
  pins, scheduler pins 7/7, bridge bearer probe, gateway bearer gate, live
  health bridge :9160 ok / apns_configured:false / voice-gw :9150
  realtime:true, public /bridge/health 200, prod parity + 3 crons armed,
  native WebRTC e2e PASS vs live gateway). Commit 1476aaa pushed.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md,
  apple-setup guide cron fires 9AM Miami tomorrow).

## 2026-09-18 12:35 UTC (build-loop run) — bridge scheduler stale-token + cancel-all contract bugs fixed; sweep all green

- Full re-audit of the server side (main.py, all 13 Swift files already
  covered in prior runs) found TWO real defects on the scheduled-call path:
- **Scheduler fired at a STALE/EMPTY device token** — `/schedule` snapshots
  the device token into the entry, but `_run_scheduler_tick` pushed to that
  snapshot forever. Empty when the call was scheduled before the device
  registered (fresh install — the exact day-one case the app fixed at 11:20)
  and stale after an app reinstall (new APNs token): "call me at 10am"
  silently never rang. Fixed: the tick now always prefers the bridge's
  CURRENT registered DEVICE_TOKEN, falling back to the snapshot only when
  nothing is registered (pre-existing state keeps working).
- **`/schedule/cancel` cancel-all was dead code** — the docstring and
  `CancelReq` ("None/empty cancels all") promised it, but the filter
  `if req.call_id and ...` kept every item when `call_id` was None.
  Empty body now clears the whole schedule as documented.
- check_scheduler_robust.py: two new pins (live-token preference, snapshot
  fallback) — 7/7 pass; cancel contract verified in a live mirror. Full
  scripts/verify_all.sh: exit 0 ALL GREEN (swift_sanity, bridge probe 15/15,
  gateway bearer gate, live health bridge :9160 ok / apns_configured:false /
  voice-gw :9150 realtime:true, public /bridge/health 200, prod parity +
  crons armed, native WebRTC e2e PASS vs live gateway). Committed 8cfb98c,
  pushed.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 12:05 UTC (build-loop run) — three audit catches: two compile blockers + dial-fail teardown; sweep all green

- Line-by-line audit (all 13 Swift files) found THREE real defects:
- **HomeView ATTENTION card: optional compile blocker** — the card body ran
  `if !a.msg.isEmpty` then `Text(a.msg)`, but `Attention.Alert.msg` is
  `String?`. Both are guaranteed Xcode errors (member access on an optional;
  no `Text(String?)` overload) — the FIRST alert to exist would have failed
  the build. Fixed with `if let msg = a.msg, !msg.isEmpty`; pinned by
  swift_sanity required-guard.
- **ChatsView.startTask: `project.map` compiles against Character** —
  `project` is a plain `String`, so `project.map { $0.components(...) }`
  iterates its CHARACTERS (`Character` has no `components(separatedBy:)`) —
  hard build error on the New-project-task path. Slug-ifies the whole string
  directly now; pinned by swift_sanity.
- **CallManager dial-fail teardown gap** — the `CXStartCallAction` catch path
  did a PARTIAL teardown (same class as the 09:02 answer-fail fix): it never
  reported the CallKit call ended (lingering system call UI after a failed
  dial) and left `pendingAnswerPayload` set (a later push could be misread as
  a re-delivery of the dead call). Routed through the idempotent
  `handleConnectionFailure` + explicit payload clear.
- Full scripts/verify_all.sh: exit 0 ALL GREEN (swift_sanity incl. new pins,
  bridge probe, gateway bearer gate, live health bridge :9160 ok /
  apns_configured:false / voice-gw :9150 realtime:true, public /bridge/health
  200, prod parity + crons armed, native WebRTC e2e PASS vs live gateway).
  Committed fc483b8, pushed.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 11:35 UTC (build-loop run) — last force-unwrapped URLs removed (AuthStore login/refresh); sweep all green

- Line-by-line audit of the auth path found the LAST remaining force-unwrap
  crash class in the app: `AuthStore` built all four request URLs with `!` —
  `URLComponents(string: "\(base)/auth/native/authorize")!`, `comps.url!`,
  and the literal `URL(string:)!` for /auth/password-login, /auth/native/token
  and /auth/native/refresh. `base` is the USER-TYPED Dashboard URL from
  Setup/Settings — a malformed value crashed the app on "Sign In". Worst of
  the four: `/auth/native/refresh` runs from CCClient's auto-refresh on any
  401, so a bad saved URL crashed the app in the BACKGROUND, unprompted (same
  crash class already fixed in WebRTCClient 08:20 and CCClient 08:40; the
  auth layer was the last holdout).
- Fix: new `AuthStore.serverURL(_:_)` helper (trims, repairs a missing
  scheme to https, returns nil on garbage). All four sites now guard-unwrap:
  login fails with "Unexpected server response (bad server URL)" and shows
  the red error line; refresh returns false (→ login screen). No force
  unwrap of a URL remains anywhere in the app.
- swift_sanity: new REQUIRED-guard pin on `serverURL(_:_)` so a revert to
  string-interpolated URL building can't land silently.
- Join logic verified in a Python mirror (scheme repair, trim, empty→nil);
  swift_sanity OK incl. new pin. Full scripts/verify_all.sh: exit 0 ALL
  GREEN (sanity, bridge 15/15, gateway bearer gate, live health bridge
  :9160 / voice-gw :9150 realtime:true, public /bridge/health 200, prod
  parity + crons armed, native WebRTC e2e PASS vs live gateway).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 11:30 UTC (build-loop run) — Chats poll identity churn + Home gateway dot now real; sweep all green

- Line-by-line audit of the remaining hot paths found two real defects:
- **Chats: poll identity churn** (`WorkThreadView.ChatLine`): `id` was a
  `let id = UUID()` stored property — synthesized `Equatable` (needed by
  pollHistory's array compare) included it, so every 5s background poll
  produced a "different" array: all bubbles got fresh identities and the
  LazyVStack rebuilt/flickered (scroll position jump) even when the thread
  hadn't changed. Fixed: content-derived `var id: String { role + "|" +
  text }` — identity, equality, and diffing all agree; a quiet poll now
  updates nothing.
- **Home: "Gateway connected" dot was hardcoded `.green`** — it lied
  whenever the dashboard couldn't reach the gateway. Fixed: the status card
  now loads `/api/control/overview` (`bridge.reachable`, the same signal the
  web CC uses) and the bridge's own `/health`; dot goes red + "Gateway
  unreachable" only on real evidence, and an "· ring pending APNs setup"
  hint appears while `apns_configured:false` (VoIP pushes still queue
  server-side — visible, not silent). Loads ride the existing per-endpoint
  `try?` resilience; error-card condition extended with the overview fetch.
- swift_sanity: REQUIRED-guard pins for both (`gatewayOK ? .green : .red`,
  content-derived ChatLine id) so neither can regress silently.
- Full scripts/verify_all.sh: exit 0 ALL GREEN (sanity incl. new pins, bridge
  15/15, gateway gate, live health, prod parity + crons, native WebRTC e2e).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 11:20 UTC (build-loop run) — fresh-install device registration + Home resilience; sweep all green

- Full re-audit (all 13 Swift files) found two more real defects:
- **Device-token registration was one-shot** (CallManager.sendDeviceToken):
  on a FRESH INSTALL the PushKit token arrives at launch — before the user
  signs in — so the single fire-and-forget POST /register 401s and the
  bridge never learns the token until the next cold launch. "Ring this
  phone" (bridge /call + scheduled calls) was dead on day one. Fixed:
  exponential-backoff retry (2/4/8/16s, 5 attempts) that re-reads the
  access token each attempt, so it upgrades itself to authed the moment
  login completes; success returns early; exhaustion falls back to the
  next launch's didUpdate callback.
- **HomeView was all-or-nothing**: one failing CC endpoint (e.g. a
  transient /zai_usage 500) threw away the whole `try await (v,z,a,w,at)`
  tuple — error card claimed the dashboard was unreachable and
  fresh-but-good data from the other four endpoints was discarded. Fixed:
  per-endpoint `try?` loads, last-known-good fallback per card, and the
  error card only appears when EVERYTHING failed.
- swift_sanity: new REQUIRED-guard pins (register retry loop, per-endpoint
  load1 pins) so neither guard can regress silently.
- Full scripts/verify_all.sh: exit 0 ALL GREEN (swift_sanity incl. new
  pins, bridge probe 15/15, gateway bearer gate, live health bridge :9160
  ok / voice-gw :9150 realtime:true, public /bridge/health 200, prod
  parity + crons armed, native WebRTC e2e PASS vs live gateway).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 11:00 UTC (build-loop run) — VoIP duplicate-push guard landed on the incoming-call path; sweep all green

- Line-by-line audit (all 13 Swift files) found the next real defect on the
  CORE path: `handleVoIPPayload` had NO re-delivery guard. APNs is
  at-least-once and the bridge retries pushes — the same `call_id` waking the
  app while that call is already ringing/active reported a SECOND CallKit
  call under a new UUID and overwrote `logEntryID`, so the real entry never
  got its outcome stamp (and the UI stacked two call cards).
- Fix: same-`call_id` re-delivery re-reports under the EXISTING uuid (CallKit
  dedupes; the report handler still runs so PushKit's completion resolves —
  Apple's contract holds). A DIFFERENT call_id while one is live is
  acknowledged + ended immediately (one-call-at-a-time), logged as "missed";
  the live call is untouched.
- swift_sanity gained a new mechanism: REQUIRED-guard pins
  (`required_guard_pins` — needle must stay present or it's a failure), since
  the existing hazard list only catches needles APPEARING. The dedupe guard
  is the first pin of this kind.
- Full `scripts/verify_all.sh`: exit 0 ALL GREEN (swift_sanity OK incl. new
  pin, drop-detection + scheduler pins, bridge bearer probe 15/15, gateway
  bearer gate, live health bridge :9160 ok / apns_configured:false /
  voice-gw :9150 realtime:true, public /bridge/health 200, prod parity +
  crons armed, native WebRTC e2e PASS vs live gateway).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 10:50 UTC (build-loop run) — second compile-blocker fixed: undefined 'prov' on the incoming-call path; sweep all green

- Line-by-line audit found another hard Xcode build error, this one on the
  CORE mission path: `CallManager.handleVoIPPayload` called
  `prov.reportNewIncomingCall(...)` — `prov` is a LOCAL inside
  `setupCallUI()`; the property is `provider`. "Cannot find 'prov' in scope"
  the moment a VoIP push arrives (the exact path this app exists for).
  Likely a leftover from the fdebb6c/2df7cb9 refactors; nothing on this box
  compiles Swift, so only the structural audit catches it.
- Fixed to `provider?.reportNewIncomingCall`; swift_sanity now carries a
  hazard pin (`prov.reportNewIncomingCall` = undefined identifier) so the
  class can't regress.
- Full `scripts/verify_all.sh` after the fix: exit 0 ALL GREEN (swift_sanity
  OK incl. new pin, drop-detection + scheduler pins, bridge bearer probe
  15/15, gateway bearer gate, live health bridge :9160 ok /
  apns_configured:false / voice-gw :9150 realtime:true, public /bridge/health
  200, prod parity + crons armed, native WebRTC e2e PASS vs live gateway).
  Committed 0b415a9, pushed.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 10:37 UTC (build-loop run) — compile-blocker fixed: ChatLine Equatable (pollHistory would fail the first real Xcode build); sweep all green

- Backlog 1–9 re-audited (git log + PROGRESS): complete, no functional drift.
- Real compile-blocker found in the line-by-line audit: `WorkThreadView.`
  `pollHistory()` compares `[ChatLine]` with `!=` (ChatsView.swift), but
  `ChatLine` never declared `Equatable` — Swift won't auto-conform, so the
  5s-reply-polling feature (25cba21) was a guaranteed Xcode build failure on
  Enrique's first archive. `ChatLine` now conforms to `Equatable`; swift_sanity
  pins the conformance so it can't regress.
- Full `scripts/verify_all.sh` after the fix: exit 0 ALL GREEN (swift_sanity OK
  incl. the new pin, bridge bearer probe, gateway bearer gate, live health
  bridge :9160 ok / apns_configured:false / voice-gw :9150 realtime:true,
  public /bridge/health 200, prod parity + crons armed, native WebRTC e2e PASS
  vs live gateway).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 10:30 UTC (build-loop run) — PushKit completion tied to CallKit report acceptance (wedge-hardening); sweep all green

- Backlog 1–9 re-audited (git log + PROGRESS): complete, no functional drift.
- Real fix found in the call path: `pushRegistry(didReceiveIncomingPushWith:)`
  resolved PushKit's `completion()` immediately after CALLING
  `reportNewIncomingCall`, not after CallKit ACCEPTED it. Apple requires the
  completion fire only once the report's own handler runs — the old ordering
  risks the killed-app crash/wedge exactly on the locked-phone incoming call
  path this app exists for. `handleVoIPPayload` now takes an `onReported`
  callback fired from the report handler; the PushKit delegate passes
  `completion` through. (swift_sanity now pins the wiring so it can't regress.)
- Full `scripts/verify_all.sh`: exit 0 ALL GREEN (swift_sanity OK incl. new
  pins, bridge bearer probe, gateway bearer gate, live health bridge :9160 ok /
  apns_configured:false / voice-gw :9150 realtime:true, public /bridge/health
  200, prod parity + crons armed, native WebRTC e2e PASS vs live gateway).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 10:35 UTC (build-loop run) — maintenance sweep all green; last stale step label fixed

- Backlog 1–9 re-audited (git log + PROGRESS): complete, no functional drift.
- Repo was already synced with origin/main (nothing unpushed).
- `scripts/verify_all.sh` step 5 label corrected ("5/5" → "5/6" — stale since
  the WebRTC e2e step landed; same class of cosmetic drift as 84984ec).
- Full sweep re-run after the fix: exit 0 ALL GREEN (swift_sanity OK, bridge
  bearer probe, gateway gate, live health bridge :9160 ok / apns_configured
  :false / voice-gw :9150 realtime:true, public /bridge/health 200, parity +
  crons armed, native WebRTC e2e PASS vs live gateway).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 10:20 UTC (build-loop run) — real Liquid Glass path landed in GlassCard (backlog #1 gap closed); sweep all green

- Drift audit found: backlog #1 promised iOS 26 `glassEffect` Liquid Glass
  styling, but `GlassCard` only ever rendered the pre-26 material fallback —
  the `#available(iOS 26.0, *)` branch was documented, never implemented.
- `ios/JarvisApp/JarvisApp.swift`: GlassCard now branches — iOS 26+ renders
  `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))`; earlier
  OSes keep the existing material fallback unchanged.swift_sanity now pins
  `glassEffect` present in JarvisApp.swift.
- Full `scripts/verify_all.sh`: exit 0 ALL GREEN (swift_sanity OK,
  scheduler-robust pin 5/5, drop-detection pin, bridge bearer probe 15/15,
  gateway bearer gate, live health bridge :9160 ok / apns_configured:false /
  voice-gw :9150 realtime:true, public /bridge/health 200, prod parity +
  reminder crons armed, native WebRTC e2e PASS vs live gateway).
- Backlog 1–9 re-audited: complete, no other drift.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 10:05 UTC (build-loop run) — TestFlight lane auto-bumps the build number; full sweep all green

- Gap closed in the Enrique ladder: the `testflight` fastlane lane uploaded with
  the project.yml-pinned `CURRENT_PROJECT_VERSION: 1` every time — the SECOND
  upload would have been rejected as a duplicate build number. The lane now
  calls `latest_testflight_build_number` + `increment_build_number` (only when
  the ASC API-key envs are set; interactive auth keeps the old manual-bump
  path, documented). Fastfile structure-checked (no Ruby on this box; balanced
  delimiter + string/comment scan passes). docs/FASTLANE.md updated.
- Backlog 1–9 re-audited: complete, no drift. Full `scripts/verify_all.sh`:
  exit 0 ALL GREEN — swift_sanity OK, scheduler-robust pin 5/5, drop-detection
  pin, bridge bearer probe 15/15 (fresh throwaway), gateway bearer gate,
  live health (bridge :9160 ok / apns_configured:false / scheduled:1,
  voice-gw :9150 realtime:true, public /bridge/health 200), prod parity +
  3 reminder crons armed, native WebRTC e2e PASS.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:55 UTC (build-loop run) — full contract re-audit vs live dashboard + live gateway: zero drift; maintenance sweep ALL GREEN

- Backlog 1–9 re-audited (git log + PROGRESS): complete; no drift in the app.
- Live end-to-end contract audit (fresh minted Bearer vs :9119): every Decodable
  model in the app re-verified field-by-field against real payloads — vitals,
  zai_usage (5h window shape), automations (items/active/failing), activity
  sessions (active field), attention (alerts incl. severity/msg/kind/ref),
  dispatch board (threads/items/ago_seconds). ALL MATCH. Routes
  /api/control/project/task + work/{id}/chat + history confirmed present in the
  live OpenAPI spec (Chats send/poll contract intact).
- Prod bridge state audit: the one scheduled entry (2030-01-01 forge-validation
  test) parses as far-future UTC → stays pending, no retry-spin; apns.env still
  empty (apns_configured:false) as expected pre-p8; scheduler robustness fix
  from 09:50 verified in the deployed file.
- Full `scripts/verify_all.sh`: exit 0 ALL GREEN (swift_sanity OK, bridge probe
  15/15 throwaway, gateway bearer gate, live health bridge :9160 + voice-gw
  :9150 realtime:true + public /bridge/health 200, parity + crons armed, native
  WebRTC e2e PASS).
- Side check: the jarvis-frontend mirror of control_center.py (e539a49, dispatch
  board null-created_at sort fix) is committed and synced with origin/main —
  live dashboard already runs it, no drift.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build → TestFlight
  upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:50 UTC (build-loop run) — scheduler robustness fix deployed: a dead loop can no longer silently drop every future scheduled call

- Gap found during this run's audit: the bridge scheduler ran every entry
  inline in a bare `while True` — one malformed `at_iso`, one push exception,
  or one corrupt `scheduled_calls.json` killed the scheduler thread
  PERMANENTLY (daemon thread, no supervisor). Every future "call me at 10am"
  would then silently never fire — the worst failure mode for backlog #8.
- `server/push_bridge/main.py`, deployed live (py_compile gate → restart →
  /health 200, public /bridge/health 200, prod state intact, scheduled:1):
  - `_run_scheduler_tick()` extracted: per-item try/except — malformed
    entries are dropped with a log line, push errors are caught.
  - Failed pushes now RETRY (failure counter per entry, capped at 10 ticks
    ≈ 3.5 min) instead of vanishing on the first unconfigured-APNs blip;
    a successful push removes the entry and logs it.
  - `_load_schedule()` no longer crashes on a corrupt state file — backs it
    up as `scheduled_calls.corrupt` once and starts fresh.
  - `_scheduler_loop()` wraps each tick in try/except so no error can kill
    the loop.
- `scripts/check_scheduler_robust.py` pins the contract (5 checks, in-process,
  temp state dir, no network); added to verify_all step 1.
- Full `scripts/verify_all.sh` re-run after the prod restart: exit 0 ALL GREEN
  (swift sanity + scheduler pin, bridge 15/15, gateway gate, live health,
  parity + crons, native WebRTC e2e PASS).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:40 UTC (build-loop run) — maintenance sweep all green; loop hygiene fixes

- Backlog 1–9 remain complete (git log + PROGRESS audit); no drift found.
- Pushed the previous run's commit (52756a4, mid-call drop detection) that was
  sitting unpushed on main — origin/main synced at 84984ec.
- verify_all.sh: stale step labels "1/4…4/4" corrected to /6 (steps 5–6 landed
  earlier but the labels never caught up) — cosmetic, committed + pushed.
- Full `scripts/verify_all.sh` re-run: exit 0 ALL GREEN — swift_sanity OK +
  drop-detection pinned; bridge probe 15/15 (throwaway :9162, prod untouched);
  gateway gate correct (valid 500 / invalid+no+refresh 401); live health bridge
  :9160 ok (apns_configured:false, scheduled:0) + voice-gw :9150 realtime:true +
  public /bridge/health 200; both services active; gateway mirror
  byte-identical; reminder crons armed; native WebRTC e2e PASS (offer → answer →
  track → app datachannel → hello → hangup) against the live gateway.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:30 UTC (build-loop run) — mid-call drop detection: lost network now fails the call instead of dead "active" air

- Remaining-gap audit after 09:20 (all backlog items 1–9 landed): once ICE
  HAD connected, a mid-call network loss (Wi-Fi→cellular handoff, dead
  gateway, tunnel drop) was never detected — `.disconnected` only failed
  the call if it had never connected, so the phone sat on "active ·
  connected" with a dead line and the log stamped "answered" forever.
- WebRTCClient (`ios/JarvisApp/WebRTCClient.swift`):
  - ICE `.disconnected` AFTER a successful connect now starts a 10 s grace
    timer (a handoff usually recovers in seconds). ICE returning to
    `connected`/`completed` cancels it — real blips ride through silently.
  - Grace expiry fires `onConnectionFailed("media connection lost (no
    recovery within 10s)")`; `failed`/`closed` also cancel the timer (no
    leak). Timer torn down in `hangup()` too.
  - Never-connected `.disconnected` stays terminal-immediate (unchanged).
- CallManager routes expiry through the existing idempotent
  `handleConnectionFailure`: CallKit call reported ended, log stamped
  "failed", PC hung up, state cleared — the dead line can no longer linger.
- `scripts/check_drop_detection.py` pins the wiring (grace armed only
  post-connect, cancel paths, end-to-end failure routing); added to
  `verify_all.sh` step 1. swift_sanity extended with the new symbols.
- Full `scripts/verify_all.sh`: exit 0 ALL GREEN (7 checks incl. bridge
  15/15 bearer probe, gateway gate, live health, parity + crons, native
  WebRTC e2e vs live gateway). App-side only — server untouched, prod safe.
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:14 UTC (build-loop run) — app can CREATE scheduled calls (last /schedule gap closed)

- Gap: the Calls tab could list + cancel scheduled calls but had no way to
  create one — `POST /schedule` was agent-only (voice tools) despite being
  bearer-live since backlog #4/5.
- CallsView: "Schedule a call…" row → new `ScheduleCallSheet` (DatePicker +
  reason) → `scheduleCall(at:reason:)` POSTs `{at_iso (ISO-8601 Z), reason,
  scheduled_by:"ios-app"}` to the bridge with the app Bearer; optimistic row
  append from the echoed `{call_id, at}`, status line, haptics. Raw ISO in the
  scheduled list now renders human-readable via `whenLabel` (Z + fractional-
  seconds parsers, raw fallback).
- Verified: swift_sanity OK (new symbols pinned). Throwaway-instance probe of
  the exact app payload shape: 5/5 — schedule (Z + +00:00 shapes), echo `at`,
  list shows entry, cancel. Full verify_all sweep: ALL GREEN (15/15 bridge
  probe, gateway gate, live health, parity + crons, native WebRTC e2e).
  Server unchanged — no deploy needed, prod untouched.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:02 UTC (build-loop run) — connect deadline actually enforced + answer-fail full teardown (drift fix)

- Audit drift: the 08:20 run's PROGRESS entry claimed a 15s connect deadline in
  `connect()`, but `waitUntilConnected(timeout:)` was NEVER called — the app
  stamped `active`/`answered` the moment the SDP answer landed, before any
  media connected. Dead-ICE calls still logged "answered" and showed
  "active · connected" with no audio. Fixed for real:
  - `connectWebRTC()` now awaits `waitUntilConnected(timeout: 15)`; on timeout
    it hangs up the peer connection and rethrows, so `active`/"answered" only
    happen when ICE actually connects.
  - The `CXAnswerCallAction` catch path did a PARTIAL teardown: it never
    cleared `activeCallUUID` nor hung up the peer connection — one failed
    answer would permanently block the one-call-at-a-time guard and leak the
    PC. It now routes into the idempotent `handleConnectionFailure` (CallKit
    ended + log "failed" + PC hangup + full state clear), same as
    `placeDirectCall`'s transaction-failure path (also consolidated).
- New `scripts/check_deadline_fix.py` pins the rewired flow (deadline call,
  PC hangup before rethrow, both fail paths into handleConnectionFailure,
  handleConnectionFailure clears UUID + hangs up). swift_sanity OK;
  full `scripts/verify_all.sh`: exit 0 ALL GREEN (bridge probe, gateway gate,
  live health, parity + crons, native WebRTC e2e vs live gateway).
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:20 UTC (build-loop run) — mid-call dead-air fix on both ends (gateway error-state push + app fail-fast)

- Backlog 1–9 re-audited (git log + PROGRESS): all landed. This run closed a
  real remaining call-path gap: **mid-call dead air**. If the gateway voice
  pipeline crashed mid-call, `VoiceSession._run()` only logged the exception —
  the client kept a live WebRTC connection to a dead pipeline (no audio, no
  hint), and the app's old `state:"error"` handler merely relabelled the call
  state without ending the CallKit call or stamping the log.
  - Gateway (`/opt/voice-gw/session.py`, deployed): `_run()` now pushes
    `{type:"state", state:"error", label:"session error: …"}` over the app
    data channel before closing. py_compile passed → restart → healthz ok →
    native WebRTC e2e probe re-run: PASS. Backup at
    `/opt/voice-gw/session.py.bak-pre-errstate`.
  - App (`CallManager.swift`): `handleAppMessage` now routes `state:"error"`
    into `handleConnectionFailure` — CallKit call reported ended, log stamped
    "failed", peer connection hung up, haptic error. Idempotency guard in
    handleConnectionFailure prevents double-teardown with the ICE path.
  - `server/voice_gateway/session.py` added to the repo as a synced mirror
    (same traceability pattern as gateway.py); ARCHITECTURE.md updated.
  - swift_sanity pins handleConnectionFailure; full `scripts/verify_all.sh`
    sweep: exit 0 ALL GREEN (bridge 15/15, gateway gate, live health, parity,
    crons, native WebRTC e2e vs the freshly restarted gateway).
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 09:05 UTC (build-loop run) — direct in-app calls: "Talk to JARVIS" works without APNs

- Gap found: the app's ONLY call path was the "Call me" button, which loops a
  VoIP push back to the same phone — dead (`pushed:false`) until Enrique
  installs the APNs p8. New **direct outgoing-call path** removes that
  dependency: the app dials the voice gateway itself, same WebRTC contract as
  answering (verified live by the e2e probe).
  - CallManager.placeDirectCall(): builds the pending payload, writes the
    outgoing log entry, and requests a CXStartCallAction transaction; the new
    `perform(CXStartCallAction)` handler reports the call started, then runs
    the exact same connectWebRTC() as incoming answer. Fail paths (including
    answer-fail, previously unstamped) now write "failed" to the log.
  - Provider/controller setup extracted to setupCallUI() and shared by both
    directions; "dialing" state stamps "missed" if ended before connect.
  - CallsView: primary gold "Talk to JARVIS" button (+ in-call "End call"),
    old push-ring demoted to a secondary "Ring this phone (server push)"
    row with an honest caption about the p8 requirement.
- swift_sanity extended (pins placeDirectCall/CXStartCallAction/setupCallUI/
  dialing/Talk-to-JARVIS symbols); structural audit 10/10 on the new path.
- Full `scripts/verify_all.sh`: exit 0 ALL GREEN (bridge 15/15 bearer probe,
  gateway gate, live health, parity + crons, native WebRTC e2e vs live gateway).
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md). Note: with this change, the app is fully
  usable for voice the moment it's installed — the p8 only adds server-rung
  calls (WhatsApp/voice "call_enrique") to the same phone.

## 2026-09-18 08:40 UTC (build-loop run) — chat thread polling + live send UX, CCClient force-unwrap removal

- **Chats: reply polling (backlog #2 gap)** — `WorkThreadView` loaded history
  once on open; agent replies that landed after a slow turn (or sent from
  WhatsApp/voice) never appeared without closing and reopening the thread.
  Now a 5 s poll (`pollHistory`, silent, skipped while `sending`) refreshes
  from the server thread and only mutates state on real diffs. Send no longer
  appends a fake "(couldn't reach JARVIS…)" assistant bubble on failure —
  the draft is restored, a red inline error line shows under the composer,
  and success shows a "JARVIS is thinking…" progress row while the turn runs.
  Empty-thread placeholder added.
- **CCClient: no more force-unwrapped URL builds** — `get`/`post` now guard
  `urlFor(path)` and throw a clean "bad server URL" failure (a malformed URL
  typed in Settings would previously crash the app). Mirrors the WebRTCClient
  hardening from 08:20 UTC.
- swift_sanity pins the new symbols (pollHistory/decodedLines/thinking row);
  full `scripts/verify_all.sh`: exit 0 ALL GREEN (bridge 15/15 bearer probe,
  gateway gate, live health, parity, native WebRTC e2e vs live gateway).
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 08:20 UTC (build-loop run) — call-path hardening: ICE-failure detection + connect deadline, no more infinite "connecting"

- Backlog items 1–9 confirmed complete (git log + docs audit). This run
  hardened the one remaining silent-failure class in the core call path:
  a gateway answer whose ICE never reaches connected (NAT mismatch, dead
  gateway, network drop mid-negotiation) used to leave the call stuck in
  "connecting" AND stamp the call log "answered".
  - WebRTCClient: new `waitUntilConnected(timeout:)` — connect() now throws
    `gateway("no media connection within 15s")` if ICE doesn't connect within
    15 s, so the CXAnswerCallAction fails fast instead of hanging.
  - WebRTCClient ICE delegate now distinguishes terminal states: `.failed`
    always fatal; `.closed`/`.disconnected` fatal only if never connected
    (normal hangup already owns the connected path). Fires new
    `onConnectionFailed(why)` callback.
  - CallManager: `handleConnectionFailure` sets callState "failed: …",
    stamps the log entry "failed" (was "answered"), reports the CallKit call
    ended, tears down the PC + haptic error. Idempotent (guards on
    activeCallUUID + current state).
  - Removed the two force-unwrapped `URL(string:)!` builds (offer + say/
    hangup paths) — a malformed server URL now throws a clean gateway error.
- scripts/swift_sanity OK; full verify_all sweep exit 0 ALL GREEN
  (6/6 incl. native WebRTC e2e vs live gateway).
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 08:05 UTC (build-loop run) — app-phase 3: Home alerts card, ad-hoc project chats, call-log outcomes

- Contract-audited the app against the live dashboard and closed three
  feature gaps in the same pass (all wire shapes verified with a minted
  Bearer against :9119 before writing code):
  - **Home ATTENTION card**: `/api/control/attention` was never surfaced —
    failed tasks / waiting sessions / failing automations only lived on the
    web CC. New `Attention` model (alerts = {severity, title, msg, kind,
    ref}; count, critical), card renders above SYSTEM only when count > 0,
    red vs yellow by severity.
  - **Chats: ad-hoc project tasks**: new "New project task…" flow → sheet →
    POST /api/control/project/task {project, text} (verified live: server
    derives conversation id `project-<slug>`); thread opens as
    `project-<slug>` — WorkThreadView now strips both `work-`/`project-`
    prefixes and the history resolver matches prefix/substring, so history
    + follow-up chat both work. Dispatch-board rows also show their latest
    item message as a subtitle (board payload re-audited: items carry
    message/ago_seconds).
  - **Call-log outcomes**: entries now carry outcome ("answered"/"ended"/
    "missed"/"failed") + durationSeconds. CallManager tracks the open log
    entry (including the outgoing entry written by the "Call me" button via
    trackOutgoingLog) and stamps it on end: duration from wall-clock start,
    decline/ring-out = missed. CallsView renders duration + outcome; store
    bumped to key v2.
- swift_sanity extended to pin every new symbol; full verify_all sweep:
  exit 0 ALL GREEN (6/6 incl. native WebRTC e2e vs live gateway).
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 07:45 UTC (build-loop run) — persistent call log (incoming + outgoing, survives restarts)

- Audited the Calls tab for silent-failure gaps and found one: the call log
  was `@State` in `CallsView` — it reset on every app restart AND incoming
  JARVIS calls (the core mission) never appeared in it at all. Fixed with a
  new `CallLogStore.swift` (UserDefaults-backed, 100-entry cap): written from
  `CallManager.handleVoIPPayload` (so a PushKit wake while killed/locked is
  recorded even if never answered) and from the "Call me" button. CallsView
  now renders the shared store; `CallEntry` struct removed.
- swift_sanity extended to structurally pin CallLogStore; full
  `scripts/verify_all.sh` sweep: exit 0 ALL GREEN (6/6 incl. native WebRTC
  e2e vs live gateway).
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).

## 2026-09-18 07:35 UTC (build-loop run) — contract audit vs live dashboard: `live`→`active` field fix

- Audited every Decodable model in the app against the LIVE dashboard
  responses (minted access Bearer, :9119): vitals, zai_usage windows,
  automations, activity sessions, dispatch board, work history. One real
  mismatch found: `Activity.Session.live` does not exist server-side — the
  dashboard emits `active` (line ~1057 control_center.py). The LIVE badge on
  Home's Current Work card would never have shown. Fixed in CCClient.swift +
  HomeView.swift.
- All other shapes verified field-by-field against live payloads (incl. the
  zai 5h window and automations item keys) — no other drift.
- Full sweep: swift_sanity OK, bridge probe 15/15 (throwaway instance, prod
  untouched), verify_all ALL GREEN, both services active, gateway mirror
  identical, native WebRTC e2e PASS.
- NEEDS ENRIQUE (unchanged): Xcode build → TestFlight upload → APNs p8
  (docs/BUILD.md, docs/FASTLANE.md).


## 2026-09-18 07:30 UTC (build-loop run) — first-call hardening (mic permission path)

- Audited the app for on-device silent-failure classes beyond the wire probes.
  Found two real gaps and fixed both:
  - **`NSMicrophoneUsageDescription` was missing** from project.yml's
    Info.plist properties. With CallKit + WebRTC, iOS hard-blocks mic access
    (and can kill the app) without it — the first real call would have failed
    on-device. Added; swift_sanity OK (xcodegen picks it up at next Mac build).
  - **Mic permission was never requested.** The prompt would otherwise land
    mid-call or be silently denied after a prior rejection, and the manual-
    audio session could start one-way. `WebRTCClient.connect()` now awaits
    `ensureMicrophonePermission()` BEFORE creating the offer (AVAudioApplication
    on iOS 17+, AVAudioSession fallback; also pre-sets playAndRecord/voiceChat
    + Bluetooth/speaker options). Denial raises a new `CallError.microphoneDenied`
    surfaced in the call-state UI via the existing catch path.
- Cleared a stale CallsView comment ("Bearer GET not enabled" for
  /schedule/list) — the bridge has used `_auth_dual` there since the 15/15
  probe commit; the app's Scheduled list was functional all along. Probe
  re-confirms: "/schedule/list shows bearer-created entry" PASS.
- Full `scripts/verify_all.sh` sweep: exit 0 ALL GREEN (6/6 incl. native
  WebRTC e2e vs live gateway). py_compile clean. Committed + pushed 0051850.
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).



- Backlog 1–9 remain complete; no drift found, nothing new actionable until
  the Enrique-gated ladder.
- Full `scripts/verify_all.sh`: exit 0 ALL GREEN — swift_sanity OK; bridge
  probe 15/15 (throwaway :9162, prod untouched); gateway bearer gate correct
  (valid 500 / bad 401); live health bridge :9160 ok + voice-gw :9150
  realtime:true + public /bridge/health 200; prod parity (both services
  active, gateway mirror identical); native WebRTC e2e probe PASS (offer →
  answer → inbound track → app datachannel → hello → hangup) against the
  live gateway. Reminder crons armed (build-loop, loop-sunset,
  apple-setup-guide). Repo clean and synced with origin/main (b52a841).
- NEEDS ENRIQUE (unchanged, the only remaining ladder): Xcode build →
  TestFlight upload → APNs p8 install (docs/BUILD.md, docs/FASTLANE.md).

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
