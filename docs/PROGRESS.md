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
