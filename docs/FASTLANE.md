# fastlane: one-command TestFlight upload (backlog #7)

Enrique's Mac only (signing + upload need his Apple identity). Everything else
was prepared agent-side: `ios/fastlane/Fastfile`, `scripts/upload.sh`.

## One-time Mac setup
1. `brew install fastlane`   (or `gem install fastlane`)
2. Auth for App Store Connect, pick ONE:
   - **API key (recommended):** App Store Connect > Users and Access > Integrations
     > App Store Connect API > generate key (Admin role, Generate API downloads).
     Download the .p8, then export before running:
     ```
     export APP_STORE_CONNECT_API_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
     export APP_STORE_CONNECT_API_KEY_ID=XXXXXXXXXX
     export APP_STORE_CONNECT_ISSUER_ID=69a6de7d-....
     ```
     (If using fastlane's built-in naming, `app_store_connect_api_key` in the
     Fastfile can read `APP_STORE_CONNECT_API_KEY_PATH/ID/ISSUER_ID` envs.)
   - **Interactive:** `export FASTLANE_USER=your@apple.id` + session password;
     expect 2FA prompts on first run.

## Every upload
```
cd jarvis-ios
git pull
./scripts/upload.sh              # xcodegen → archive → TestFlight upload
./scripts/upload.sh --build-only # compile/sign sanity check, no upload
```
Or straight: `cd ios && fastlane testflight`.

Build numbers: the `testflight` lane auto-bumps `CURRENT_PROJECT_VERSION` from
the latest live TestFlight build (`latest_testflight_build_number` + 1) whenever
the App Store Connect API-key envs are set — no manual edits needed. With
interactive auth (no API key) it skips the bump: bump it by hand in
ios/project.yml if TestFlight rejects a duplicate build number.

## Notes
- First SPM resolve pulls the ~400MB WebRTC binary (see BUILD.md backlog-#4 note).
- TestFlight processing takes ~5-15 min; the Fastfile skips waiting
  (skip_waiting_for_build_processing) so the command returns fast.
- The JARVIS-box agent will ping Enrique's WhatsApp DM when a build is needed
  (backlog #8 reminder hook).
