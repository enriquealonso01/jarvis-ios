# BUILD (Enrique's manual ritual)

**SUPERSEDED for builds/uploads**: the full pipeline is automated — push tag
`ios-v*` (or dispatch lane `beta` on .github/workflows/ios-release.yml) builds,
signs, and uploads to TestFlight via GitHub Actions. First SHIPPING build is
build 1 (run 35391242548, 2026-09-18 20:26 UTC, VALID in ~90 s); earlier runs
35378698056/35383128608 produced builds 19/20/21 which Apple ITMS-rejected
(90683, missing camera purpose string — fixed in 2fed80a). The Xcode ritual
below is the fallback only.

You only ever do these steps. Everything else is agent-deployed.

## One-time (per Mac)
1. `git clone https://github.com/enriquealonso01/jarvis-ios.git` (private repo — private-repo clone is pushed and live)
2. `cd jarvis-ios/ios && xcodegen` (XcodeGen: `brew install xcodegen`) — generates JarvisApp.xcodeproj from project.yml
3. Open `ios/JarvisApp.xcodeproj`
4. Signing & Capabilities: select your Personal Team (the one tied to your Apple Developer sub)
5. Product > Scheme > JarvisApp; destination: any iPhone

## Every update cycle (agents tell you when via WhatsApp DM)
1. `git pull`
2. In Xcode: Product > Archive
3. Window > Organizer > Distribute App > TestFlight (internal)
4. TestFlight app on phone: update, install

## First build after backlog #4 (WebRTC added)
- `ios/project.yml` now pulls the Google WebRTC (STS) prebuilt via SPM
  (stasel/WebRTC mirror, pinned at 130.0.0 — verified live upstream). After
  `xcodegen`, open the project and let Xcode
  resolve the package (File > Packages > Resolve Latest Package Versions) —
  first resolve downloads ~400MB, be patient. Then sign + run as usual.
- VoIP push background mode (`voip` in UIBackgroundModes) is already set.
- Push Notifications entitlement (`aps-environment`) is already wired via
  `JarvisApp.entitlements` (CODE_SIGN_ENTITLEMENTS in project.yml). After you
  select your team, Signing & Capabilities should show "Push Notifications"
  ON the target — if it's missing, add it manually from + Capability.
- CallKit reporting happens inside the PushKit callback (iOS hard
  requirement); do not remove the PushKit registration from AppDelegate.

## First TestFlight setup — DONE (2026-09-18)
- ASC app record "EA's J.A.R.V.I.S" (id 6813590605), bundle reassigned to
  com.enriquecodes.jarvis. Build 19 uploaded by CI run 35378698056.
- RESOLVED (2026-09-18 ~20:40 UTC): the "stuck ingest" was a misdiagnosis.
  Builds 19/20/21 FAILED Apple asset validation with **ITMS-90683** (missing
  NSCameraUsageDescription) — rejections are invisible in /v1/builds and only
  show up in GET /v1/apps/{id}/buildUploads. After commit 2fed80a added the
  purpose string, build 1 (CI run 35391242548, uploaded 20:26 UTC) passed
  validation in ~90 s: processingState=VALID, internalBuildState=IN_BETA_TESTING,
  autoNotify on, export compliance pre-marked, auto-added to the internal
  group "App Store Connect Users" (no manual betaGroups POST needed — a POST
  returns 422 "cannot be assigned" when membership is already automatic).
- Remaining: (1) Phone: install TestFlight, accept the internal-tester invite
  (enriquealonsorequejo@icloud.com), install build 1, open it once — the app
  POSTs /register to the bridge on launch, which makes VoIP pushes live.
  (2) No ASC web-UI banner check needed anymore: ingest was never stuck;
  internalBuildState=IN_BETA_TESTING is the authoritative all-clear.

## ASC build-visibility watcher
- DONE & self-removed: cron `testflight-build-watch` (d6d31d5fec17) polled ASC
  until build 1 appeared (VALID, 2026-09-18 ~20:28 UTC), pinged, and deleted
  itself as designed. Its poller lives on as the repo script
  `scripts/poll_asc_builds.py` (canonical copy survives reboots; the original
  /tmp copy did not). Key detail: the APNs .p8 doubles
  as the ASC API key but the JWT **issuer** is the ASC issuer ID
  (cbd7e0fd-925b-4aa8-8ce1-facbc1b39881), NOT the APNS_TEAM_ID — a
  team-ID issuer gets HTTP 401. The poller reads both kid and issuer
  itself; run with `--expect 1` to filter to a single version. Any
  "BUILD:" line on stdout = build visible.

## APNs key status (the blocker before first ring)
- The installed key (kid 2PMV4SF2LS, in /opt/jarvis-ios-bridge/apns.key) is
  valid for the ASC API but REJECTED by APNs itself: both push hosts answer
  `403 InvalidProviderToken` to a correctly signed provider token (checked
  2026-09-18 22:20 with scripts/probe_apns_delivery.py — sandbox AND
  production, multiple iat skews, curl + httpx). The key was evidently
  created without the "Apple Push Notifications service (APNs)" capability.
- NEEDS ENRIQUE (web, 2 min): developer.apple.com → Certificates, Identifiers
  & Profiles → Keys → + create a key with **Apple Push Notifications service
  (APNs)** checked → download the .p8 and send it (or drop it in a one-time
  link). Everything else is agent-side, ONE COMMAND:
  `python3 scripts/swap_apns_key.py --p8 <file> --key-id <NEWKID>` — the
  script GATES the candidate key before touching anything live:
  (1) PEM EC-key format check, (2) it must actually sign an ES256 provider
  token, (3) Apple must answer `400 BadDeviceToken` to a dummy token signed
  with it (same wire shape as probe_apns_delivery.py). Any other verdict
  (403 InvalidProviderToken = another ASC-only key, 429 churn, network) →
  hard refusal, live config untouched. On pass it installs the key 0600,
  updates apns.env + the repo template kid atomically (with rollback), and
  NO restart is needed — the bridge's `_send_voip` re-reads env per push.
  After the swap: `scripts/probe_apns_delivery.py` (no args) must print
  `400 BadDeviceToken` against the LIVE paths, then verify_all step 1b can
  drop `--warn` and go gate-mode. The probe's verdict covers TWO legs: curl
  AND the bridge's exact production client (httpx + h2 from the bridge venv,
  the "BRIDGE-STACK" leg) — a bridge-transport regression fails the probe
  even when curl answers fine.
- Live rejection surfacing: the bridge records every APNs non-200 in
  apns.env (`LAST_PUSH_ERROR=403 InvalidProviderToken at <ts>`, cleared on
  the first 200) and `/health` exposes it as `last_push_error` — the app's
  Home card prints it and verify_all's live-health step fails loudly if it
  names InvalidProviderToken. A bad key can no longer hide between sweeps.
  TRANSPORT failures are recorded the same way (`transport <Error> at <ts>`):
  `_send_voip` wraps the POST itself, so an h2 handshake failure or timeout
  returns a LOUD recorded False instead of 500-ing POST /call.
- verify_all step 1b runs this probe every sweep (WARN mode) so the verdict
  stays visible until fixed. The watch,
  `jarvis-ios-device-watch` (15m, 192 repeats, script-mode, delivers to the
  TF Ops Signal group), now waits on BOTH remaining flips and announces each
  once: (1) KEY LIVE — installed APNs key ACCEPTED by Apple, detected by
  running scripts/probe_apns_delivery.py (exit 0 = verdict 400
  BadDeviceToken), which fires the moment the replacement .p8 is installed
  via swap_apns_key.py; (2) REGISTERED — bridge /health device_registered
  flips true (whitespace-tolerant match). It self-removes ONLY when both
  bits are set (either order) — a registered phone on a still-rejected key
  keeps the watch alive. Each flip path was TESTED END-TO-END on
  2026-09-18 (stub probe + stub :8799 health → KEY LIVE + REGISTERED +
  MISSION COMPLETE lines + `hermes cron remove` executing, using a
  sacrificial job name so the real watch can never delete itself in a
  test); the self-remove failure is LOUD (manual-removal WARNING instead
  of swallowed). The live script is mirrored byte-identical
  at `scripts/testflight_device_watch.sh`, and its whole wiring contract
  (target bridge, JOB pin, cron spec, delivery group, mirror) is pinned by
  `scripts/check_watch_wiring.py`, run as step 5c of verify_all.sh. To
  change the watch: edit the repo mirror, `cp` it to
  /root/.hermes/scripts/, then run verify_all.
- POLLER GOTCHA (cost hours on 2026-09-18): GET /v1/builds lists only builds
  that PASSED asset validation. A rejected upload (ITMS-90683 etc.) never
  appears there, which looks exactly like a stuck ingest. The poller now
  also prints "UPLOAD:" lines from /v1/apps/{id}/buildUploads (real
  validation state + ITMS codes) and a "BETA:" line (internalBuildState)
  for the newest build — always check UPLOAD lines before diagnosing.

## Notes
- TestFlight builds expire after 90 days — the loop agent will remind you well ahead.
- No App Review is involved for internal testers (up to 100 devices).
