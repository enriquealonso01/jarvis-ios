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
