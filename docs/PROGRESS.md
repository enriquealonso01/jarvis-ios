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
