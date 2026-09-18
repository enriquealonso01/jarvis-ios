# BUILD (Enrique's manual ritual)

**SUPERSEDED for builds/uploads**: the full pipeline is automated — push tag
`ios-v*` (or dispatch lane `beta` on .github/workflows/ios-release.yml) builds,
signs, and uploads to TestFlight via GitHub Actions (first green run 35378698056,
2026-09-18 18:14 UTC, build 19). The Xcode ritual below is the fallback only.

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
- Remaining: (1) ASC UI — open EA's J.A.R.V.I.S → TestFlight and check for a
  banner (new Apple terms/agreement or an ingest error) and accept it. Three
  uploads (builds 19/20/21, Sep 18) reached Apple but no build record was ever
  created (~80 min, vs ~4 min for HeRose on the same team/.p8) — the app record's
  ingest looks stuck; a banner-accept usually clears it. (2) Phone: install
  TestFlight, accept the internal-tester invite (enriquealonsorequejo@icloud.com),
  install the build once it appears, open it once — the app POSTs /register to
  the bridge on launch, which makes VoIP pushes live.

## ASC build-visibility watcher
- Cron `testflight-build-watch` (d6d31d5fec17, every 15m) polls
  `GET /v1/builds?filter[app]=6813590605` until a build record appears,
  then pings Enrique and self-removes. Its poller is the repo script
  `scripts/poll_asc_builds.py` (canonical copy survives reboots; the
  original /tmp copy did not). Key detail: the APNs .p8 doubles as the
  ASC API key but the JWT **issuer** is the ASC issuer ID
  (cbd7e0fd-925b-4aa8-8ce1-facbc1b39881), NOT the APNS_TEAM_ID — a
  team-ID issuer gets HTTP 401. The poller reads both kid and issuer
  itself; run with `--expect 19` to filter to a single version. Any
  "BUILD:" line on stdout = build visible.

## Notes
- TestFlight builds expire after 90 days — the loop agent will remind you well ahead.
- No App Review is involved for internal testers (up to 100 devices).
