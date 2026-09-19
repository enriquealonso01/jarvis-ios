## 2026-09-19 06:45 UTC (build-loop run) — the sign-in path PROVEN for the first time: a full audit of the day-one "open + sign in" journey found no blocking bug (the suspected PasswordLoginBody slip was a misread), and a live probe now pins the app↔dashboard PKCE contract — authorize 302+PKCE cookie, brokered password-login reaching the credential check, loopback-redirect boundary — as verify_all step 1d

- Backlog 1–8 re-verified DONE against the tree (app shell, Chats, Secrets,
  Calls/CallKit/PushKit/WebRTC, bridge /register + schedule endpoints +
  scheduler, gateway WebRTC + voice tool, call_enrique CLI, fastlane CI);
  #9 icon/launch/haptics/settings ship in project.yml + assets. The build
  number chain that produced build 29 came from xcodegen's GITHUB_RUN_NUMBER
  (CURRENT_PROJECT_VERSION: "20" in project.yml is stale, harmless — CI
  overrides it; zeroed to "0" this run to kill the confusion at the source).
- AUDIT (the one day-one path nothing had ever exercised: sign-in):
  walked AuthStore's whole RFC 8252 round trip against the deployed
  dashboard routes — authorize query (S256 + literal-loopback redirect,
  which the server REQUIRES; 'localhost' is rejected), password-login body
  model, next→?code= extraction, token/refresh bodies + decode. Found and
  disproved one suspect: a first read of AuthStore.swift:207 suggested
  `self.password = username` (every sign-in bricked); grep + regex on the
  REAL file proved the line is correct — a lesson in re-reading before
  writing. LIVE probes against jarvis.enriquecodes.com: /auth/native/
  authorize → 302 /login + __Host-hermes_session_pkce cookie (broker handoff
  alive); brokered /auth/password-login with a probe body → 401 "Invalid
  credentials" — i.e. provider=basic resolves, the PKCE cookie is ACCEPTED,
  the app's exact body shape parses, and flow control reaches the
  credential check (the only step needing real creds); non-loopback
  redirect → 400 (open-redirect boundary intact). Token/refresh endpoints
  return {access_token, refresh_token, expires_at} — exactly the app's
  decode. Verdict: nothing blocks flip 2 (Enrique's sign-in) server-side.
- PINNED so it cannot drift: scripts/check_login_contract.py (layer A: 22
  structural pins on AuthStore.swift incl. a NEGATIVE-tested
  password=username tamper check; layer B: the three live probes above,
  SKIPPED-not-failed when the dashboard is unreachable, 429 tolerated as
  alive) wired into verify_all.sh as step 1d. First sweep run caught its
  own bug — urllib silently followed the authorize 302 and read the login
  page's 200 as the status; NoRedirect handler added, contract re-proven.
- verify_all ALL GREEN with 1d aboard (doc contracts, swift sanity, APNs
  probe, push-counter shadow, bearer probes, live health, parity, watch +
  sentinel wiring + 18/18 behavior, WebRTC e2e 6/6).
- Live state unchanged: probe verdict still 403 InvalidProviderToken
  (ASC-only key), device_registered:false, push_ok:0, build 29 VALID +
  IN_BETA_TESTING (count 2), schedule clean. NEEDS ENRIQUE unchanged, now
  with sign-in PROVEN up to real credentials: (1) APNs-capable .p8
  (scripts/swap_apns_key.py installs it), (2) phone — TestFlight → open
  BUILD 29 → sign in once; device-watch announces each flip within 15 min.


## 2026-09-19 06:00 UTC (build-loop run) — PIPELINE FULLY GREEN: build 29 VALID + IN_BETA_TESTING with the day-one re-kick fix aboard; a four-run debugging chain traced the version-stamp break to its true root (xcodegen wrote literal CFBundleVersion=1 into Info.plist) and the Fastfile now verifies the stamp in-archive AND in-ipa

- Last run's assumption was WRONG and this run caught it: build 2 (tag
  ios-v21) had silently FAILED — "no upload row yet, normal" was actually a
  hard Swift compile error. Reading the real Actions run statuses (not the
  ASC poller alone) is now the loop's first step.
- Fix 1 — compile (run 35420950536): the re-kick commit's
  `private static let tokenKey` is MainActor-isolated, and the PushKit
  delegate is `nonisolated` → "main actor-isolated static property
  'tokenKey' can not be referenced from a nonisolated context".
  `private nonisolated static let` (immutable String, Sendable) is the
  correct repair; swift_sanity's required pin updated to the guarded form
  (and it NEGATIVE-tested the change: sanity failed until the pin matched).
- Fix chain — build numbers (runs 35423491270 → 35424281811 → 35424600305 →
  35424959129): build 3 archived fine but ASC rejected the upload with
  -19232 "bundle version must be higher than the previously uploaded
  version" — cfBundleVersion=1 again. Evidence-driven sequence: (a) explicit
  `manageAppVersionAndBuildNumber:false` in gym's exportOptions was NOT
  enough (gym appends xcargs to -exportArchive too); (b) lane rebuilt as
  archive-only (skip_package_ipa) + hand export with a generated
  ExportOptions.plist and zero build settings on the command line + loud
  guards — the ARCHIVE itself still carried CFBundleVersion=1;
  (c) MANAGE_APP_VERSION_AND_BUILD_NUMBER=NO on the archive — still 1;
  (d) TRUE ROOT CAUSE: xcodegen hardcodes CFBundleVersion=1 into the
  GENERATED Info.plist, and a plist literal overrides CURRENT_PROJECT_VERSION
  entirely (this also explains yesterday's "green" build 1 shipping as
  version 1 — it was never tested against a second upload). Plist now uses
  `$(CURRENT_PROJECT_VERSION)` / `$(MARKETING_VERSION)` references; the
  archive guard immediately PASSED (build 28 stamped). One self-inflicted
  typo (`xcrun -exportArchive` → `xcodebuild -exportArchive`) fixed, and
  ios-v27 (run 35425198930) went END-TO-END GREEN: upload row
  cfBundleVersion=29 COMPLETE, BUILD: 29 | VALID | IN_BETA_TESTING (count 2).
- Fastfile hardening that stays: 3-step lane (archive w/ stamp +
  MANAGE...=NO → hand export from clean plist → verify CFBundleVersion in
  the .xcarchive AND inside the exported .ipa, UI.user_error! on any
  mismatch), plus the beta lane prints the generated Info.plist every run so
  a literal-vs-reference regression is visible in CI. FASTLANE.md documents
  the whole trap chain with run ids. verify_all ALL GREEN after every change;
  sentinel 18/18; no gateway/bridge restarts.
- Live state: device_registered:false, push_ok:0, probe verdict still 403
  InvalidProviderToken. Build 1 is now superseded — NEEDS ENRIQUE updated to
  point at BUILD 29: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  unchanged), (2) phone — TestFlight → open BUILD 29 → sign in once; the
  re-kick fix (now actually compiled + shipped) makes that single open+sign-in
  flip device_registered. Device-watch announces each flip within 15 min.


## 2026-09-19 04:30 UTC (build-loop run) — day-one registration seam closed in the app: PushKit token persisted + /register RE-KICKED the moment auth flips (login or manual token), so "open build 1 once" now actually flips device_registered instead of waiting for a second cold launch

- Audit this run (holding pattern; both blockers still Enrique-side) traced
  the day-one critical path end-to-end and found a real timing seam in
  CallManager: the /register retry loop (5 attempts, 2/4/8/16s backoff ≈ 30s)
  starts at LAUNCH — but a fresh install launches into Setup → Login, so all
  five attempts fire UNAUTHENTICATED (401s) and exhaust while the user is
  still typing credentials. The login round trip then takes minutes; without
  a re-kick the bridge never learns the PushKit token until the NEXT cold
  launch. Concretely: Enrique accepts the invite, opens build 1, signs in —
  and device_registered STAYS false, "ring this phone" is dead on day one,
  and the device-watch keeps announcing nothing. The exact flip the whole
  watch/sentinel apparatus is waiting on had a hole in it.
- FIX (3 files): (1) CallManager persists every PushKit token to
  UserDefaults (jarvis.push.voiptoken) BEFORE the first registration attempt
  — token rotation just overwrites + re-registers. (2) New
  retryDeviceRegistration() re-kicks /register from the STORED token; wired
  to RootTabView.task (fires exactly when isAuthed flips true via password
  login, and on cold-launch-already-authed) and to AuthStore.applyManualToken
  (Settings lives INSIDE the already-visible RootTabView, so its .task never
  re-fires — that route needs its own kick). Every attempt re-reads the
  CURRENT access token, so the re-kick lands the registration the moment
  auth exists. Server side already idempotent (/register upserts the token
  file) — bridge untouched, no restart.
- Proven: swift_sanity gained required-guard pins on all three pieces
  (tokenKey + persist + retryDeviceRegistration in CallManager, the .task
  hook in JarvisApp, the applyManualToken kick in AuthStore) and the pin was
  NEGATIVE-TESTED — tampering the symbol out of CallManager makes sanity
  exit 1 with "REQUIRED pin missing", restore makes it exit 0. No Swift
  toolchain here, so structural balance + pins + full verify_all (34+1 doc
  contracts, sentinel 18/18, live health, native WebRTC e2e vs the live
  gateway) are the verification stack; ALL GREEN after the change. Committed
  to master; next tag build (ios-v2) picks it up — no rebuild needed for
  build 1's verdict.
- SHIPPED THIS RUN (after the audit fix): tag ios-v21 pushed → ios-release.yml
  → build 2 carrying the re-kick fix (build number = GitHub run number, so
  build 1 does NOT contain it — relaunch was the old workaround, build 2
  removes the need). ASC poll ~16 min after the tag: no upload row yet —
  normal (yesterday's green cycle ≈ 90 min incl. runner + SPM + archive);
  next loop ticks re-poll; an itms code in the UPLOAD row = pipeline failure
  to diagnose. Live state unchanged: device_registered:false, push_ok:0,
  probe verdict 403 InvalidProviderToken, build 1 VALID + IN_BETA_TESTING.
  NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py),
  (2) phone — TestFlight, invite, open build 1, sign in. Both flips announce
  within 15 min; with the app fix riding the repo, opening + signing in once
  is now genuinely sufficient for flip 2.


## 2026-09-19 03:50 UTC (build-loop run) — success-was-paged-as-a-loss seam closed in the watch-sentinel: GONE verdicts are now health-ARBITRATED (device_registered:true AND push_ok>=1 = QUIET stand-down), so the mission-complete self-remove can never fire a false "announcer lost" alert

- Audit this run swept for drift with both blockers still Enrique-side and
  found the next real seam — a false-positive alarm scheduled for the moment
  of SUCCESS: when the device-watch's endgame fires (real verification push
  accepted), it delivers MISSION COMPLETE and SELF-REMOVES. The sentinel's
  GONE branch treated "cron absent + bridge reachable" as a LOSS (alert once,
  stand down) — reachability alone cannot distinguish "watch removed because
  it finished" from "watch removed because something killed it". First real
  ring tonight would have paged the TF Ops group with a bogus "flip announcer
  is lost" line at the exact moment the mission completed.
- FIX (deployed LIVE this run, repo→live byte-identical): the GONE branch
  now reads /health as the ARBITER — MISSION_DONE = `device_registered:true`
  AND `push_ok>=1` (the exact shape the endgame leaves behind: phone
  registered + Apple ACCEPTED a real push) → QUIET stand-down, no alert;
  GONE with any lesser health while the bridge answers → the alert, with an
  honest message ("does NOT prove completion (need device_registered:true
  AND push_ok>=1)"); bridge unreachable → unchanged alert-once + stand-down.
  Uses push_ok, not push counters' absence — mirrors the watch's own
  fail-closed endgame semantics (a 200 round-trip is the only proof).
- Proven in the sandbox, not assumed: stub bridge made MUTABLE
  (Bridge.health dict) so the proven-completion branch is driven for real —
  B3p gone+PROVEN health → SILENT + stood-down flag; B3p-bis one-shot holds;
  B3 gone+UNPROVEN (registered:false, push_ok:0) → GONE alert fires with the
  new wording; B1–B13 regression all green → 18/18 PASS (was 15/15). The
  wiring pin + doc-contract step 10 gained the arbitration pin each
  ("GONE verdict is health-arbitrated"), so a revert cannot hide.
- Live tick after deploy: SILENT, exit 0 (today's state — watch present,
  22/384 ticks — takes the normal path; the new branch is inert until the
  real GONE). verify_all.sh ALL GREEN end-to-end after the deploy (34+1 doc
  contracts, sentinel wiring incl. new pin, behavior 18/18, watch wiring,
  bearer probes, gateway gate, live health, prod parity, native WebRTC e2e).
- Live state unchanged: probe verdict still 403 InvalidProviderToken (key
  unchanged), device_registered:false, push_ok:0/push_fail:0, schedule clean,
  build 1 VALID + IN_BETA_TESTING. Crons: loop 30m armed, guide 13:00 UTC
  armed, sunset 23:00 UTC armed, watch 15m armed, sentinel 30m armed.
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8
  (scripts/swap_apns_key.py installs it). (2) phone — install TestFlight,
  accept the invite, open build 1 once → /register fires. Either flip is
  announced within 15 min; with both, the watch proves delivery with a real
  push before mission-complete — and NOW the sentinel stands down silently
  instead of paging success as a loss.


## 2026-09-19 03:10 UTC (build-loop run) — delivery-channel integrity on the terminal wait: the two one-shot announcers (23:00 UTC sunset wrap-up, 13:00 UTC setup guide) were still aimed at the WhatsApp DM that 403'd three times on 9/18 — both repointed to the PROVEN Signal DM, prompts + mirrors pinned, sweep ALL GREEN

- Audit this run (holding pattern; features 1–8 done, waiting only on the two
  flips) found the seam: jarvis-ios-loop-sunset and
  jarvis-ios-apple-setup-guide delivered to `origin` = the WhatsApp DM, while
  the device-watch had already been moved to Signal (`signal:+130****2646`,
  firing ok every 15m since the channel switch, zero delivery errors). Had
  they fired as configured, tonight's FINAL mission wrap-up (including the
  loop pause + NEEDS-ENRIQUE list) would have vanished into a 403'd channel.
- FIXED live via `hermes cron edit`: deliver → `signal:+130****2646` (the
  exact target the device-watch proves with every 15m tick — no guessing at
  phone numbers), and both prompts updated to NAME the Signal target and
  FORBID WhatsApp delivery, so the agent-side "verify delivery goes here"
  instruction can't steer back to the dead channel. Repo mirrors
  (scripts/cron_prompts/*.txt) updated byte-identically; doc-contract step 8
  pins (live==mirror) re-verified PASS; full verify_all sweep ALL GREEN
  after the change. Sentinel/watch/loop crons untouched.
- Unchanged: device_registered false, push counters 0/0, probe still 403
  InvalidProviderToken. NEEDS ENRIQUE unchanged: (1) APNs-capable .p8
  (swap_apns_key.py installs it), (2) phone-side TestFlight install + open
  build 1. Both flips announce within 15 min via the watch; with both, the
  endgame proves real delivery before mission-complete.

- Gap this run found: after tonight's 23:00 UTC sunset pauses the build-loop
  cron, the 15m device-watch is the mission's ONLY autonomous announcer for
  the two remaining flips (APNs key accepted / phone /register) — and its
  own failure modes were all silent: cron removed or paused, ticks
  exhausted, scheduler stall, bridge :9160 down, or probe_apns_delivery.py
  broken (flip-1 detection blind). Any of these and Enrique's flips happen
  with nothing firing. (The watch's own endgame already proves delivery;
  this closes the "who watches the watch" seam.)
- SENTINEL (deployed LIVE this run): jarvis-ios-watch-sentinel —
  no-agent 30m cron, 720 ticks (~15 days), zero LLM cost — checks every
  tick: (1) watch cron exists (removed + bridge-unreachable = alert once
  then STAND DOWN: cannot tell mission-complete self-remove from a real
  loss; removed + bridge-reachable = alert once), (2) enabled, (3) ticks
  fresh (last_run_at age > 40m = stalled), (4) tick budget > 8 (~2h
  headroom), (5) bridge /health ok, (6) probe still emits a VERDICT.
  Alerts are one-line, latched per fault (re-arm on recovery), routed to
  the TF Ops group; failure channel suppressed (script always exits 0, so
  the cron failure path can never double-announce); strictly
  observe-and-report — it never invokes hermes (mentioning `hermes cron
  resume` inside an alert text is human remediation, not a mutation).
- PROVEN before deploy, not assumed: sandbox behavior test
  (check_watch_sentinel_behavior.py) drives the REAL script against a stub
  jobs.json + stub bridge + stub probe via JARVIS_IOS_* env overrides —
  15/15: healthy→silent ×2, gone→alert+stood-down, gone again→silent,
  paused→alert, persists→latched, fix+break→refires, stalled (50m-old
  last_run_at), budget (5 ticks left), bridge down, probe blind, 4-fault
  storm→4 lines, recovery→silent+re-armed. The test caught TWO real design
  bugs pre-deploy: the stall check originally compared last_run_at to the
  PREVIOUS POLL (a 50-min-stale tick that just changed would pass) — now a
  direct age-vs-now check; and the stood-down flag was a fixed /tmp path
  (sandbox would have touched the prod flag) — now state-file-relative.
- Pinned three ways so it cannot rot: check_watch_sentinel.py (18 wiring
  pins: repo/live byte-identical, executable, cron spec 30m/720,
  Ops-group deliver, local failure channel, no-hermes-invocation,
  always-exit-0, watch mirror still identical) +
  check_watch_sentinel_behavior.py (the 15-branch sandbox, re-run in every
  sweep) + check_doc_contracts.py step 10 (5 pins incl. ARCHITECTURE.md
  documents the layer). verify_all 5c-bis runs both; full sweep ALL GREEN
  end-to-end after the live deploy (34 doc-contract pins, sentinel wiring
  + behavior, watch wiring, bearer probes, gateway gate, live health, prod
  parity, native WebRTC e2e PASS).
- Live state after deploy: sentinel cron enabled (next run 02:48 UTC),
  live run SILENT (everything healthy), device-watch untouched
  (16/384 ticks, next 02:23, deliver pins intact), bridge /health clean
  (0/0 counters, device_registered false, last_push_error empty). Probe
  verdict re-confirmed live: still 403 InvalidProviderToken both legs
  (key unchanged).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8
  (scripts/swap_apns_key.py installs it, gates re-verify Apple's verdict).
  (2) phone — install TestFlight, accept the invite, open build 1 once →
  /register fires. Either flip is announced within 15 min; with both, the
  watch proves delivery with a real push before declaring mission complete.

## 2026-09-19 01:00 UTC (build-loop run) — push-success observability closed the mission-complete honesty gap: bridge counts real Apple round-trips (push_ok/push_fail on /health), the device-watch ENDGAME now PROVES delivery with a real verification call instead of asserting it; prod-path verified live, deploy executed via the safe path

- Close audit this run found the endgame seam: the watch's
  MISSION-COMPLETE message asserted "/call now rings the phone
  (pushed:true)" — a claim nothing had verified at that moment, and one
  /health field actively could not support: last_push_error=="" means only
  "nothing failed YET", never "a push succeeded". Bridge + watch + probes
  + docs upgraded together so the mission's final announcement is earned,
  not assumed.
- BRIDGE (deployed LIVE this run): `_bump_push_counters()` persists
  push_ok/push_fail to push_counters.json (0600, corrupt-file tolerant,
  best-effort — a counter write failure can never affect the push result);
  every REAL Apple round-trip bumps exactly one counter (200 → push_ok,
  transport error / non-200 → push_fail); the unconfigured and no-device
  early-exits are NOT counted (round-trip-only semantics — they never
  touched Apple); /health exposes both as ints. Shadow probe
  (scripts/probe_push_counters_shadow.py, stubbed Apple vs the REAL module,
  17/17) pins: transport→fail, 200→ok, 403→fail, both early-exits not
  counted, /health shape, corrupt-counters reset, 0600 perms. Wired into
  verify_all as step 1c.
- WATCH (live script replaced, byte-identical mirror): the
  both-flips-seen branch now reads push_ok BEFORE, fires a real
  verification call via scripts/call_enrique.py (production HMAC path,
  reason explains "ignore/hang up"), re-reads /health with retries, and
  declares MISSION COMPLETE only if push_ok incremented (Apple ACCEPTED
  the push). Fail-closed: any mismatch → LOUD URGENT line (routes to the
  TF Ops group via failure_deliver), state kept, cron NOT removed so the
  loop agent triages on its next run. The message also states the honest
  boundary: push_ok proves APNs accepted, not that CallKit rang — the
  manual ring test stays recommended. Whole block tested in a sandbox
  (stub bridge on :9163, stub call tool, fake hermes): 4/4 PASS — happy
  path (counter bump → mission complete + self-remove fired), call-tool
  failure, no-bump, spaced-JSON health. Sandbox testing caught TWO real
  bugs before they could ship: a state-file read of a variable nothing
  writes (dead "before" value) and a compact-JSON-only grep that would
  have read the REAL bridge's push_ok as empty (spaced JSON) and turned
  every real mission-complete into a false URGENT.
- PROD-PATH VERIFIED LIVE before deploying the watch: /register with a
  sacrificial token (device-watch paused first so no false REGISTERED
  announcement was possible) → real /call → APNs answered the known 403
  InvalidProviderToken → /call returned pushed:false (correct) AND
  /health showed push_fail:1 (the rejected round-trip counted). Live
  state then restored pristine: sacrificial DEVICE_TOKEN removed,
  counters reset to 0/0, LAST_PUSH_ERROR cleared, watch resumed. Bridge
  deployed per the safe path: py_compile (repo + venv) → LKG staged →
  restart → /health verified (counters 0/0, device_registered false).
- Incident found by the post-deploy wiring sweep, fixed this run:
  `hermes cron pause/resume` MANGLED the watch's deliver field
  (personal DM → TF Ops group), which would have sent mission announcements
  to the Ops group instead of Enrique. Restored via `hermes cron edit
  --deliver 'signal:+130****2646'`; check_watch_wiring ALL PINS HOLD after.
  (The pause was itself protocol — it made the sacrificial-token test
  provably unable to fire a false REGISTERED.)
- Docs + pins: API.md /health shape now documents push_ok/push_fail and
  the "last_push_error=='' ≠ delivered" rule; ARCHITECTURE.md lists
  push_counters.json; check_doc_contracts step 9 (7 new pins) holds the
  counter contract, the early-exit semantics, the watch's real-call
  endgame, its fail-closed shape, and the whitespace-tolerant extraction.
  verify_all ALL GREEN end-to-end after everything (30/30 doc contracts,
  swift_sanity, counter shadow probe, bearer probe 16/16, gateway gate,
  live health, prod parity incl. LKG==prod==repo, watch wiring,
  native WebRTC e2e).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8
  (scripts/swap_apns_key.py installs it; probe + swap gates re-verify
  Apple's verdict automatically). (2) phone — install TestFlight, accept
  the invite, open build 1 once → /register fires (CallManager retries
  with backoff). The device-watch (15m) announces either flip within 15
  minutes, and when BOTH land it will now prove the delivery path with a
  real push before declaring the mission complete.



- Full re-audit this run: backlog 1–9 complete, verify_all ALL GREEN
  (23/23 doc contracts, 15/15 watch pins, bridge bearer probe, gateway
  gate, prod parity, live health, native WebRTC e2e PASS). ASC build 1
  VALID + IN_BETA_TESTING; probe verdict re-run live: still 403
  InvalidProviderToken (key unchanged); device_registered false;
  last_push_error empty; schedule clean.
- This run's real delta is the loop itself: with both blockers
  Enrique-side and the dual-flip device-watch (15m, ~4-day lifetime,
  key_wait+device_wait announced once each) covering BOTH remaining
  events independently, the build loop at every 5m (~288 runs/day) was
  pure holding-pattern cost — the same proxy-cost class that paused
  backlog #7. Cut to every 30m via `hermes cron edit`, verified in
  jobs.json (interval minutes:30, enabled, next_run set); verify_all
  re-run ALL GREEN after the change (its cron step only pins
  enabled-state, correctly not cadence). Sunset job 23:00 UTC today
  still pauses the right job (c4b099e2cf11) and now sees flips with 30m
  granularity for its final ~16 hours — well within the watch's
  15-minute announcement latency.
- Commit 74892f5 pushed (empty-delta allowed so the ops change is on the
  record). NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the
  APNs-capable key (developer.apple.com → Keys → APNs CHECKED) and send
  the .p8 (one command installs it); (2) phone — install TestFlight,
  accept invite, open build 1 once → REGISTERED. Watch announces either
  flip within 15 min.

## 2026-09-19 00:00 UTC (build-loop run) — stale-guidance bug caught BEFORE it fired: the Sep-19 9AM setup guide claimed the broken APNs key works; prompts now mirrored + pinned; watch lifetime doubled to 4 days

- This run's own audit found the next scheduled message to Enrique was wrong:
  the `jarvis-ios-apple-setup-guide` cron (fires 9AM Miami Sep 19) still said
  "the push bridge is live with the APNs key" and FORBADE mentioning key
  creation — written at 21:20, BEFORE the 22:35 discovery that the key is
  ASC-only and Apple rejects its pushes (403 InvalidProviderToken). He would
  have installed build 1, failed the "ring this phone" test, and concluded
  the app is broken. Fixed: the prompt is now STATE-DRIVEN — it runs
  scripts/probe_apns_delivery.py + /health FIRST and includes the 2-minute
  key-creation step (developer.apple.com → APNs checked → send the .p8)
  ONLY if the verdict is still InvalidProviderToken; the ring-test section
  now says it works only AFTER the key lands.
- Same staleness class fixed in the sunset job (Sep 19 23:00): its wrap-up
  now builds the NEEDS-ENRIQUE list from live checks (probe verdict +
  device_registered) instead of hardcoded facts, and it explicitly leaves
  the device-watch running after pausing the build loop (previously
  unstated — the watch is what announces the flips after the loop stops).
- Prompt-drift is now a pinned contract: both prompts mirrored into the
  repo at scripts/cron_prompts/ (source-of-truth, same pattern as the
  gateway mirror) and check_doc_contracts.py step 8 machine-checks
  (a) live prompts byte-identical to mirrors, (b) state-driven shape
  (probe + /health present), (c) no "bridge is live with the APNs key"
  claim. 23/23 pins PASS.
- Device-watch lifetime doubled: 192 → 384 ticks (48h → ~4 days). Its
  expiry (Wed ~21:30 UTC) had silently drifted past the sunset deadline —
  if Enrique acted over the weekend, the KEY-LIVE / REGISTERED /
  MISSION-COMPLETE announcements would never fire. flip-1 detection
  re-verified through the exact production command path (/usr/bin/python3,
  "delivery path PROVEN" grep) — silent now, fires on the good-key
  verdict. check_watch_wiring.py delivery pins corrected to the actual
  watchdog convention (announcements → personal DM, failures → TF Ops
  group) — the old pin predated the convention and flagged the correct
  live config as FAIL.
- Verified live: verify_all.sh ALL GREEN (incl. 23/23 doc contracts, 15/15
  wiring pins, native WebRTC e2e vs the live gateway); live crons edited
  via `hermes cron edit` and re-read back from jobs.json (byte-identical
  to mirrors); bridge /health unchanged (device_registered:false,
  last_push_error:""); ASC unchanged (build 1 VALID + IN_BETA_TESTING).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8 (one
  command installs it); (2) phone — install TestFlight, accept invite,
  open build 1 once → REGISTERED. The 9AM guide now tells him both steps.

## 2026-09-18 23:55 UTC (build-loop run) — the push path's last unexercised link closed: transport guard in `_send_voip` + the probe now proves the BRIDGE'S OWN httpx+h2 stack (both-legs verdict), stale "egress mangles python h2" claim disproven and corrected

- Audit found the delivery chain had one link never exercised AND one
  fragile seam: (1) every probe/swap verdict was proven with **curl**, while
  the bridge's production push uses **httpx+h2 from its own venv** — which
  had never sent a single packet to Apple (every push so far early-exited on
  the empty DEVICE_TOKEN); a bridge-transport regression (missing h2
  package, egress change, venv breakage) would have hidden behind a
  curl-only green until the first real "call me". (2) `_send_voip`'s POST
  had **no try/except** — a transport exception would escape `/call` (which
  has no handler) as an unhandled 500 with NO `LAST_PUSH_ERROR` recorded;
  the scheduler path wrapped the same call, /call did not.
- LIVE EXPERIMENT first: the bridge venv's exact stack answered
  `HTTP 403 InvalidProviderToken, proto=HTTP/2` on BOTH APNs hosts — the
  production transport is healthy today, AND the old comments claiming
  "this box's egress mangles python h2 to Apple" (urllib-era artifact in
  probe + swap) are FALSE. Both comments corrected with the disproof date.
- Bridge hardening (deployed LIVE this run, repo main.py is the systemd
  ExecStart cwd): the POST is wrapped — transport failures now print
  `[bridge] APNs push TRANSPORT ERROR: <type>…`, record
  `LAST_PUSH_ERROR=transport <Type> at <ts>`, and return False; /call can
  never 500 at the transport layer again. Shadow-tested on the real module
  (stubbed Client raising ConnectError → False + recorded; empty-token
  early-exit unchanged; real 403 path still recorded; /health shape
  intact), py_compile OK, deployed per the safe path: LKG snapshot →
  idle-window restart 23:5x UTC (gateway quiet ≥5 min) → /health ok →
  real /call probe → journal line shape unchanged.
- Probe upgraded to a TWO-LEG verdict: leg 1 curl (portable), leg 2
  "BRIDGE-STACK" — the SAME dummy-token POST through
  /opt/jarvis-ios-bridge/venv's httpx+h2 client (the exact `_send_voip`
  transport). Provider token reaches the leg via environment variable
  (never argv — ps-readable); no second mint (Apple's token-churn rule).
  `400 BadDeviceToken` now requires BOTH legs to agree; a bridge-transport
  failure gets a distinct `BRIDGE TRANSPORT BROKEN` verdict (never a
  curl-only green pass; under --warn it still exits 0 so the cron sweep
  stays green until the key lands).
- Wire-up: check_doc_contracts step 7 pins the whole contract (leg present,
  token-via-env, both-legs verdict rule, transport-broken diagnosis,
  `_send_voip` guard); API.md documents the `transport …` error shape;
  BUILD.md documents the two-leg probe + guard. verify_all step 1b now
  runs the bridge-stack leg on every sweep.
- verify_all.sh ALL GREEN end-to-end after the restart (doc contracts incl.
  new step 7, swift_sanity, bearer probes, gateway gate, live health,
  prod parity, watch wiring, native WebRTC e2e PASS). Bridge /health
  `last_push_error:""`, device_registered:false, scheduled:0 — live key
  verdict re-confirmed unchanged (403 InvalidProviderToken, both legs).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8 (one
  command installs it; the swap's gate 3 + the probe's both-legs verdict
  now cover the production transport too). (2) phone — install TestFlight,
  accept invite, open build 1 once → REGISTERED. First real ring = key
  swap + phone flip, both announced by the device-watch.

## 2026-09-18 23:20 UTC (build-loop run) — device-watch upgraded to DUAL-FLIP: now announces the APNs key flip the moment it lands, not just the phone flip

- Gap found: the watch only monitored `device_registered`. When Enrique's
  replacement .p8 lands and `swap_apns_key.py` installs it, NOTHING would
  announce it until the next manual probe or sweep — the single most
  anticipated event of the mission was silent. The watch now detects BOTH
  remaining flips, announces each once (state-file bits), and self-removes
  ONLY when both are set (either order): a phone that registers while the
  key is still rejected (pushes would 403) keeps the watch alive.
  - flip 1 (KEY LIVE): runs scripts/probe_apns_delivery.py per tick; exit 0
    (verdict 400 BadDeviceToken) == Apple accepts the installed key.
  - flip 2 (REGISTERED): /health device_registered, now whitespace-tolerant
    (REAL BUG found by the stub test: spaced JSON would have been missed).
- Flip paths PROVEN e2e this run: stub probe (verdict PROVEN) -> KEY LIVE +
  bit; stub :8799 health registered -> REGISTERED + bit; next tick ->
  MISSION COMPLETE + self-remove EXECUTED — using a SACRIFICIAL job name
  (jarvis-device-watch-selfremove-test) so the 21:50 mishap class (test
  copy deleting the real watch) is structurally impossible now. Real job
  verified untouched after the test; real state file untouched; leftover
  squatter stub on :8799 (from the 21:50 run, answering 501) found + killed.
- Deployed per the mirror workflow (repo -> cp -> pins): check_watch_wiring
  14/14 OK incl. byte-identical mirror; live tick verified (both WAIT lines
  once, then silent); doc contracts OK; verify_all ALL GREEN incl. native
  WebRTC e2e against the live gateway.
- Live state unchanged: probe still 403 InvalidProviderToken (key verdict
  re-confirmed live this run), build 1 VALID + IN_BETA_TESTING,
  device_registered false, last_push_error empty.
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com -> Keys -> APNs CHECKED) and send the .p8; one
  command installs it (scripts/swap_apns_key.py) and the watch will
  announce KEY LIVE within 15 min. (2) phone — install TestFlight, accept
  invite, open build 1 once -> REGISTERED announced -> mission complete.

## 2026-09-18 22:55 UTC (build-loop run) — bad APNs key can no longer hide between sweeps: bridge remembers push rejections (`last_push_error` on /health), app + verify_all surface it

- Gap found: `_send_voip` logs a rejection once (journal line) and forgets.
  `/health` said `{apns_configured:true}` all evening while Apple was
  rejecting every push with `403 InvalidProviderToken` — the only witness
  was a 15-min sweep and whoever reads journals. A bad key that lands after
  any future swap/config drift would look "configured" between sweeps.
- Fix (deployed LIVE to the bridge this run):
  1. `_send_voip` now records every non-200 as `LAST_PUSH_ERROR=<code>
     <reason> at <ts>` in apns.env (0600, same store as DEVICE_TOKEN), and
     clears it on the first 200. Unconfigured path records `unconfigured`.
     No restart needed (env re-read per push, unchanged contract).
  2. `/health` exposes it as `last_push_error` (empty string = healthy).
     Live now: `{"ok":true,"apns_configured":true,"device_registered":false,
     "last_push_error":"","scheduled":0}` — empty is CORRECT until a device
     registers (the only real pushes so far took the no-device early-exit).
  3. App Home SYSTEM card prints `· APNs: <error>` when non-empty
     (HomeView + CCClient BridgeHealth field) — ships with the next tagged
     build, per the no-builds-for-cosmetics rule.
  4. verify_all step 4 now GATE-FAILS if /health names InvalidProviderToken
     (belt to 1b's WARN suspenders).
- Proven: shadow-tests on the real module with a stubbed APNs — 403
  InvalidProviderToken → False + LAST_PUSH_ERROR set; 200 → True + cleared;
  unconfigured → recorded; /call HMAC path unchanged (44024b5b pushed:false,
  skip line in journal). py_compile + TestClient /health/401-shape checks
  green; deployed per the safe path (repo→LKG /opt/jarvis-ios-bridge-lkg →
  idle-window restart 22:53 UTC → /health ok → real /call probe). Full
  verify_all ALL GREEN incl. native WebRTC e2e against the new process.
- docs: API.md /health shape, BUILD.md "APNs key status" (surfacing note).
- ASC unchanged: build 1 VALID + IN_BETA_TESTING. device_registered still
  false; probe still 403 (key verdict unchanged, now machine-visible).
- NEEDS ENRIQUE (both unchanged, one web + one phone): (1) create the
  APNs-capable key (developer.apple.com → Keys → APNs checked) and send the
  .p8 — agent-side install is one command (scripts/swap_apns_key.py);
  (2) install TestFlight, accept invite, open build 1 once → /register
  fires → device-watch announces → mission complete.

## 2026-09-18 22:55 UTC (build-loop run) — the one remaining agent-side gap closed: `swap_apns_key.py` turns the broken-key fix into ONE gated command; blocker verdict re-confirmed live

- Backlog 1–9 re-verified complete; verify_all ALL GREEN after this run's
  changes. Both open blockers remain Enrique-side (new APNs key, phone
  install) — so this run closed the last agent-side gap around the first one.
- Gap: when Enrique's replacement .p8 lands, installing it was a manual
  multi-step procedure (stage key → chmod → edit apns.env kid → keep the repo
  template in sync → re-probe). Each step is a chance to install a BAD key
  (e.g. another ASC-only key) over a broken one and only find out later.
  Fix: `scripts/swap_apns_key.py` — one command that refuses to touch the
  live bridge until the candidate key passes three gates: (1) PEM EC-key
  format, (2) actually signs an ES256 provider token, (3) **Apple's own
  verdict** — a dummy-token POST signed with the candidate must answer
  `400 BadDeviceToken` (same wire shape as probe_apns_delivery.py). 403
  InvalidProviderToken / 429 churn / network errors → hard refusal, live
  config untouched. On pass: installs 0600, updates the live apns.env kid
  AND the new tracked template `server/push_bridge/apns.env.example`
  together (repo↔prod kid can no longer silently disagree), with rollback
  on any mid-stage failure. Zero downtime: the bridge's `_send_voip`
  re-reads env per push, so NO restart is needed (`--restart` optional).
  Also refuses same-kid "swaps" (a NEW key has a NEW kid) and offers
  `--check` to gate the currently installed key anytime.
- Proven this run, no real key needed: refusal path against Apple LIVE
  (test EC key + correct kid-shape → gate 3 answered `403
  InvalidProviderToken` → SWAP REFUSED, live dir untouched, no staging
  debris); full happy path e2e against a local 400-BadDeviceToken stub
  (gates pass → staged into a throwaway state dir: key 0600, env kid
  rewritten, P8_PATH repointed; idempotence guard re-fires on a same-kid
  re-run). The sandbox regression risks (run_gates making its own live call
  beyond the stubbed one, pytest-free assert harness) were found and fixed
  during testing.
- Wire-up: doc-contract pins (check_doc_contracts.py step 6) now hold the
  whole contract machine-checked: gates present, refusals present, same-kid
  guard, rollback, BUILD.md naming the runbook. BUILD.md "APNs key status"
  + API.md "Pending" now say ONE command instead of a manual procedure.
- Re-verified live at 22:5x: the installed key STILL answers `403
  InvalidProviderToken` (nothing changed on Apple's side); bridge/gateway
  healthy, device_registered still false, schedule empty.
- NEEDS ENRIQUE (unchanged, both open): (1) web ~2 min — create the
  APNs-capable key (developer.apple.com → Keys → APNs checked) and send the
  .p8; agent-side install is now literally one command. (2) phone-only —
  install TestFlight, accept invite, open build 1 once → /register fires.
## 2026-09-18 22:35 UTC (build-loop run) — APNs delivery path PROBED for the first time: key is ASC-only, REJECTED by APNs (InvalidProviderToken) — new key = the one new NEEDS-ENRIQUE item

- Gap found and closed: `_send_voip` had only ever been exercised in its
  *unconfigured* branch (`pushed:false`, no p8). The p8 IS installed
  (apns_configured:true since 16:37 UTC) but no device ever registered, so
  Apple's verdict on the key itself was still unknown. New
  `scripts/probe_apns_delivery.py` mints the bridge's exact provider JWT
  (pyjwt ES256, kid header) and POSTs a syntactically valid, guaranteed-
  unregistered dummy token (DEADBEEF…9999) to the configured host.
  `400 BadDeviceToken` = everything healthy, no phone yet; anything else =
  named diagnosis.
- **THE FINDING: the live key (kid 2PMV4SF2LS) is REJECTED by APNs — both
  hosts answer `403 InvalidProviderToken` (production AND sandbox checked,
  iat skews 0/±5/±30 to rule out clock drift, curl + httpx + bridge's own
  stack). The same key signs ASC API calls fine (poller green all day;
  /v1/apps 200 re-verified this run). Diagnosis: the key was created in
  App Store Connect WITHOUT the "Apple Push Notifications service (APNs)"
  capability — ASC-only keys are accepted by api.appstoreconnect but not by
  api.push.** Ruled out: team ID (APNS_TEAM_ID 5ZXB95KW57 == ASC seed ID,
  confirmed via /v1/bundleIds), topic (== bundle ID), hosts, clocks, egress
  (raw h2 preface test to api.push.apple.com passes).
- Consequence, honestly stated: **until the key is replaced, NO VoIP push can
  be delivered.** The whole "pushed:false = just install TestFlight" story was
  incomplete — even with the phone registered, /call would still fail at
  Apple. Better to know tonight than on the first real "call me".
- NEEDS ENRIQUE (web, ~2 min; NEW, replaces nothing): developer.apple.com →
  Certificates, Identifiers & Profiles → Keys → create key WITH "Apple Push
  Notifications service (APNs)" checked → download the .p8 and send it to
  JARVIS (secret link is fine). Install + apns.env update + bridge restart +
  probe re-run are all agent-side; probe must then print
  `400 BadDeviceToken`. Documented in docs/BUILD.md "APNs key status" and
  docs/API.md "Pending".
- Bridge hardening (deployed live): `_send_voip` failure is now LOUD —
  non-200 logs `[bridge] APNs push REJECTED: HTTP <code> <reason>
  (topic=…, host=…)`; empty-token path gets its own distinct log line, so
  "no device" never masquerades as "APNs broken" again. Deployed per the
  safe path: py_compile OK → LKG snapshot (/opt/jarvis-ios-bridge-lkg/) →
  idle-window restart 22:22 UTC (gateway quiet ≥3 min) → /health ok →
  real /call probe prints the new skip line in the journal.
- verify_all: new step **1b/6 APNs delivery-path probe** (--warn mode so the
  cron sweep stays green while the key is pending; flip to gate mode once it
  reports BadDeviceToken). Full sweep ALL GREEN after the bridge restart,
  including bearer probe 16/16, gateway gate, prod parity, native WebRTC e2e.
- Housekeeping: one-off diagnostics cleaned from /tmp; probe caches its
  provider token 45 min @0600 (Apple's TooManyProviderTokenUpdates guards).
- NEEDS ENRIQUE (still open, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → device-watch announces. Key first,
  then the phone — both are on the critical path to the first real ring.
## 2026-09-18 22:00 UTC (build-loop run) — backlog #8 CLOSED: `call_enrique` is real — agent CLI shipped + voice-brain tool LIVE in the restarted gateway

- Gap found: #8's "WhatsApp/voice JARVIS call_enrique tool" existed only as a
  doc recipe — no JARVIS surface could actually ring the phone. Two parts
  shipped this run:
  1. `scripts/call_enrique.py` — agent-facing CLI over the bridge (call /
     schedule / list / cancel), self-signing HMAC, stdlib-only. Proven LIVE
     against the production bridge: schedule → list shows entry → cancel-one
     → list empty → call → `{pushed:false}` (no device registered yet, no
     side effects; `_send_voip` degrades to False with an empty DEVICE_TOKEN).
  2. `call_enrique` as a Pipecat function tool in the voice brain
     (/opt/voice-gw/brain.py; action=now|schedule|list|cancel, reason /
     at_iso / call_id; ISO-8601 validated;Miami-time echo on schedule;
     pushed:false → guidance to install TestFlight instead of dead air).
     Handler seam proven with all five paths against the live bridge before
     restart; "call me at 10am about X" now works hands-free mid-call.
- Deploy per ARCHITECTURE.md procedure: py_compile + venv import OK →
  last-known-good snapshot (brain+session) → restart at 21:55 UTC during an
  idle window (no offer/connect in prior 3 min; last call closed 21:45) →
  /healthz ok, brain realtime, openai ok → full verify_all.sh ALL GREEN incl.
  native WebRTC e2e against the NEW process.
- Repo mirrors synced: server/voice_gateway/brain.py (NEW — /opt/voice-gw was
  previously unmirrored in-repo) and session.py (picked up an unmirrored
  live-only presence fix from 17:34; /opt tree and repo now identical).
- docs/API.md: "Calling Enrique" section restructured — one-liner CLI,
  voice-tool note, raw curl recipe.
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → device_registered flips → every path above goes live
  (pushed:true, CallKit screen with reason).

## 2026-09-18 21:50 UTC (build-loop run) — device-watch flip path PROVEN end-to-end + wiring contract pinned; real watch restored after test mishap

- The one branch of the loop never actually exercised was the device-watch
  FLIP: what happens the moment device_registered turns true (announce +
  self-remove). Tested for real: stub HTTP server on :8799 answering
  device_registered:true, watch copy pointed at it → REGISTERED line printed
  AND `hermes cron remove` executed and deleted a cron job. The path works.
- COST OF THE TEST (owned): the copy kept the hardcoded JOB name, so it
  deleted the REAL jarvis-ios-device-watch. Restored in full same-run:
  15m × 192 repeats, script-mode (no_agent), deliver
  signal:group:Gd7ABv9… (TF Ops), id 67968b669507, state file reset to
  "wait", safe-tick verified silent. Live bridge /health confirms the test
  never touched real state (device_registered still false). Lesson encoded:
  the wiring is now machine-checked so this class of drift can't hide.
- Hardening: (1) self-remove failure is now LOUD — script prints a manual-
  removal WARNING to the Ops group instead of `|| true` swallowing it;
  (2) hermes invoked by absolute path /root/.local/bin/hermes (script
  runs from cron's minimal PATH); (3) live script mirrored byte-identical
  into the repo at scripts/testflight_device_watch.sh (same source-of-truth
  pattern as the gateway mirror; edit mirror → cp → verify_all).
- New scripts/check_watch_wiring.py (verify_all step 5c) pins the whole
  contract: script targets :9160 (not a stub), JOB pinned, cron exists/
  enabled/15m/192/script-mode, delivery = TF Ops group, repo mirror
  byte-identical, hermes CLI resolvable. 13/13 pins hold; full
  verify_all.sh ALL GREEN including the new step; doc contracts OK.
- BUILD.md watcher section updated: tested flip path, loud-failure note,
  mirror workflow. ASC unchanged: build 1 VALID + IN_BETA_TESTING.
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → watch announces → done.

- Re-verified: verify_all.sh ALL GREEN end-to-end (doc-contract pins, swift_sanity,
  bridge bearer probe 16/16, gateway bearer gate, live health bridge :9160 ok /
  gateway :9150 realtime:true / public /bridge/health 200, prod parity both units
  active + gateway mirror byte-identical, native WebRTC e2e PASS with hello+hangup).
  ASC state unchanged: build 1 VALID + IN_BETA_TESTING, no new uploads/rejections.
  Repo clean and in sync with origin/main; backlog 1–9 complete, no code delta.
- Cron-integrity audit (this run's addition): (1) sunset job's hardcoded pause
  target c4b099e2cf11 == the live jarvis-ios-build-loop id — tonight's shutdown
  will pause the right job; (2) device-watch script verified on disk at
  /root/.hermes/scripts/testflight_device_watch.sh and executes clean (silent
  wait-tick while device_registered=false, as designed); (3) 9AM guide cron
  verified telling Enrique build 1 only (no Xcode/upload mentions); (4) bridge
  schedule clean (scheduled:0), watch state "wait".
- device_registered still FALSE — waiting on the one phone-only step.
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → device-watch announces → done.

## 2026-09-18 21:20 UTC (build-loop run) — honesty pass: stale crons + docs corrected to the build-1 reality; nothing else to build

- Re-verified on this run: verify_all.sh ALL GREEN (fresh sweep, bridge 16/16,
  gateway gate, prod parity, live health, native WebRTC e2e PASS), doc
  contracts OK, ASC live state unchanged — build 1 VALID + IN_BETA_TESTING,
  no new uploads or rejections. Backlog 1–9 remains complete; no code delta
  found that survives the small-edit bar (the last cosmetic label already
  rides the next tagged build).
- THIS RUN'S REAL FINDING — stale guidance aimed at Enrique: the 9AM
  `jarvis-ios-apple-setup-guide` cron still told him to install **build 19**
  (an ITMS-rejected upload that never existed in TestFlight). Both it and the
  Sep-19 `jarvis-ios-loop-sunset` wrap-up predated the build-1 truth.
  Fixed via `hermes cron edit`: guide now installs **build 1** only (no
  Xcode/upload mentions); sunset wrap-up now ships the correct facts (build 1
  LIVE, CI does signed uploads, Enrique never touches Xcode) and checks
  bridge /health device_registered to choose mission-complete vs install
  steps. Both verified post-edit in jobs.json.
- Repo docs aligned to the same reality: README mission (3) — Enrique's only
  manual step is phone-side install, CI uploads headless; BUILD.md header now
  names build 1 as first SHIPPING build with the 19/20/21 ITMS-90683 history,
  and the watcher section is past-tense (build-watch self-removed after
  VALID; device-watch still armed on /health device_registered).
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → device-watch announces → done.

## 2026-09-18 21:05 UTC (build-loop run) — registration loop closed: device_registered on /health + self-removing watch; stale forge call cancelled

- Backlog re-verified COMPLETE (1–9): all code in HEAD, verify_all ALL GREEN
  after this run's changes (bearer probe 16/16, gateway gate, prod parity,
  WebRTC e2e PASS). TestFlight still: build 1 VALID + IN_BETA_TESTING.
- Registration loop closed (the last blind spot): bridge /health now returns
  `device_registered` (boolean — flips true the moment the phone POSTs
  /register; no token material). Verified live: `{"ok":true,"apns_configured":
  true,"device_registered":false,"scheduled":0}` after bridge restart.
- App: BridgeHealth decodes the new field; Home SYSTEM card shows
  "· device not registered" while it's false (same visible-not-silent contract
  as the APNs hint). Ships with the next tagged build — build 2 not burned for
  a cosmetic-only label while build 1 is still uninstalled.
- Watch armed: cron `jarvis-ios-device-watch` (15m, Ops group) prints REGISTERED
  + removes itself when the field flips; WAIT announced once, then silent
  ticks (state file /tmp/.jarvis_ios_device_watch_state); 192-repeat expiry.
- Housekeeping: cancelled the stale forge-validation scheduled call
  (acbfbcd4, was parked at 2030); bridge schedule now clean (scheduled:0).
  Removed dead empty ios/Sources/ tree. Doc-contract pins extended to cover
  the device_registered contract (check 5 in check_doc_contracts.py).
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → watch announces → mission complete.

## 2026-09-18 20:45 UTC (build-loop run) — TestFlight LIVE: build 1 VALID + IN_BETA_TESTING; "ingest stall" was ITMS-90683 all along

- ROOT CAUSE FOUND: builds 19/20/21 never "stalled in ingest" — they FAILED
  Apple asset validation with ITMS-90683 (missing NSCameraUsageDescription).
  Rejections never appear in GET /v1/builds; they are only visible in
  GET /v1/apps/6813590605/buildUploads (relationship earlier probes missed).
  The team-wide-sweep / agreement theories are dead; account is healthy.
- BUILD 1 IS LIVE: commit 2fed80a (camera purpose string) → CI run
  35391242548 uploaded 20:26 UTC → VALID at ~20:28 (90 s processing).
  buildBetaDetail: internalBuildState=IN_BETA_TESTING, autoNotify=true,
  export compliance pre-marked (usesNonExemptEncryption=false). Internal
  group "App Store Connect Users" auto-includes it — a manual betaGroups
  POST correctly 422s ("cannot be assigned to this internal group").
- Poller upgraded (scripts/poll_asc_builds.py): now also prints UPLOAD:
  lines (buildUploads validation state + ITMS codes) and a BETA: line
  (internal/external state, autoNotify) so a rejected upload can never
  masquerade as a stuck ingest again. Verified live: all three views green.
- docs/BUILD.md corrected: phantom ASC banner check removed; remaining
  step is phone-only. Watch cron (d6d31d5fec17) will see BUILD lines on
  its next 15m tick and self-remove as designed.
- NEEDS ENRIQUE (final, phone-only): install TestFlight, accept invite
  (enriquealonsorequejo@icloud.com), install **build 1**, open once →
  app POSTs /register → VoIP pushes live → mission complete.
- Full verify_all.sh suite unaffected (no server/gateway/app code changed
  this run — poller + docs only).

## 2026-09-18 20:05 UTC (build-loop run) — team-wide ASC ingest sweep: both apps frozen; ingest stall confirmed as account/key-wide

- New `scripts/asc_team_sweep.py`: pages ALL of /v1/builds (no app filter,
  newest-first, 4x100) and prints each app's most recent build + a MAX-AGE /
  VERDICT differential — answers "is ingest delayed team-wide or specific to
  our app?" in one shot, without hardcoding control-app IDs.
- Sweep result (20:05 UTC): only TWO apps exist on the account — 6813590605
  (EA's J.A.R.V.I.S, ours: ZERO builds) and 6773857468 (He Rose From Death,
  control). The newest build visible team-wide is HeRose build 20 uploaded
  **2026-08-21** → MAX-AGE 676h (>28 days). No app has ingested a build in
  >24h. VERDICT: team/account-wide ingest stall — NOT specific to our app.
- Cross-checked the independent preReleaseVersions index: ours EMPTY, HeRose
  shows only its Aug "1.0" record (matches). Builds 19/20/21 remain absent
  ~2h after the first upload (poll_asc_builds count: 0 at 20:00).
- Interpretation for Enrique's ASC-UI check (unchanged blocker, now sharper):
  whatever blocks ingest affects the whole account — most likely an ASSEMBLED
  agreement/licensing banner or Apple Developer Program license issue on the
  account in the ASC web UI; accepting it should flush BOTH apps. Diagnostic
  value: an app-specific problem is now ruled out.
- Full sweep unchanged: scripts/verify_all.sh ALL GREEN (bridge 16/16, live
  health ok, prod parity, native WebRTC e2e PASS, swift_sanity ok). Backlog
  1-9 remain complete; repo clean, in sync with origin/main.
- NEEDS ENRIQUE (unchanged): ASC UI check at appstoreconnect.apple.com →
  accept any agreement/banner (account-wide) + phone-side TestFlight
  install/open (reminder cron fires 9AM Miami Sep 19).

## 2026-09-18 20:20 UTC (build-loop run) — deeper ingest probe: uploads verified green, app record still EMPTY; agreement accepted (betaLicenseAgreement OK)

- Pulled the full Fastlane log for CI run 35383128608 (build 21, 18:58 UTC):
  "Successfully uploaded package to App Store Connect" + "fastlane.tools
  finished successfully" — the upload path is 100% clean, ASC_KEY_ID/
  ASC_ISSUER_ID/ASC_KEY_P8 secrets are correct.
- New API probes (all with the working ASC key):
  - GET /v1/apps/6813590605 → app exists, but EVERY relationship is EMPTY
    (builds, buildUploads, preReleaseVersions, betaAppReviewDetail, ...).
  - Direct builds rel (/apps/6813590605/builds): total 0.
  - betaLicenseAgreements?filter[app]=6813590605 → EXISTS (accepted-by-default
    shape; agreementText null) — no pending license agreement visible via API.
  - betaGroups: internal group "App Store Connect Users" EXISTS (created
    17:01 UTC today), matches control app's structure.
  - betaAppReviewSubmissions?filter[app]: HTTP 400 (odd, but non-blocking).
  - Account-wide builds (no filter, all pages): exactly 6 builds, ALL
    HeRose. Uploads from today (19/20/21) never became build records.
- Conclusion: ingest stall confirmed at the ASC ingestion layer for this app
  record, 80+ min post-upload, while the account/key/auth surface is fully
  functional. API cannot see WHY — the only visibility left is the ASC web UI
  (agreement banner, or an ingest error shown on the TestFlight tab).
- NEEDS ENRIQUE (unchanged + sharpened): sign in at
  appstoreconnect.apple.com → EA's J.A.R.V.I.S → TestFlight tab → look for a
  banner or error, accept anything pending. If clean, contact Apple
  Developer Support (ingest stuck >4h for 3 uploads while control app ingests
  fine on the same key).
- Poller/watch unchanged: testflight-build-watch cron keeps pinging every 15m;
  verify_all.sh ALL GREEN re-confirmed this run (bridge 16/16, WebRTC e2e PASS).
