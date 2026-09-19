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

Build numbers: the `archive` lane stamps `CURRENT_PROJECT_VERSION` from
`GITHUB_RUN_NUMBER` (local runs: a timestamp) via xcargs on the ARCHIVE step
only, then verifies the number three times: in the .xcarchive, inside the
exported .ipa's Info.plist, and before upload.
XCODE 26 TRAP (hit on runs 35423491270, 35423976015 + 35424281811): xcodebuild
ARCHIVE now resets CFBundleVersion to 1 by default (automatic app-version
management), ignoring CURRENT_PROJECT_VERSION, and gym appends xcargs to the
-exportArchive command too, where build settings switch export into the same
mode — ASC then rejects the upload with -19232 ("bundle version must be
higher than the previously uploaded version"). The lane counteracts BOTH: the
archive carries MANAGE_APP_VERSION_AND_BUILD_NUMBER=NO next to the stamp, the
export is done by hand with a generated ExportOptions.plist and ZERO build
settings on the export command, and the lane fails loudly unless the stamp is
verified in the archive AND inside the exported .ipa. If you edit the lane,
keep both countermeasures and both verification points.

## Notes
- First SPM resolve pulls the ~400MB WebRTC binary (see BUILD.md backlog-#4 note).
- TestFlight processing takes ~5-15 min; the Fastfile skips waiting
  (skip_waiting_for_build_processing) so the command returns fast.
- The JARVIS-box agent will ping Enrique's WhatsApp DM when a build is needed
  (backlog #8 reminder hook).
