#!/usr/bin/env bash
# Backlog #7: one-command TestFlight upload, for Enrique's Mac.
#
# Usage (on the Mac, in the repo root):
#   ./scripts/upload.sh              # xcodegen + archive + TestFlight upload
#   ./scripts/upload.sh --build-only # archive only, no upload
#
# Auth: either `fastlane app_store_connect_api_key` env vars (APP_STORE_CONNECT_*,
# recommended), or interactive FASTLANE_USER/FASTLANE_PASSWORD. See docs/BUILD.md.
set -euo pipefail
cd "$(dirname "$0")/../ios"

if [[ ! -d fastlane ]]; then
  echo "Run from the repo: scripts/upload.sh (cd's into ios/ itself)." >&2
  exit 1
fi

if [[ "${1:-}" == "--build-only" ]]; then
  exec bundle exec fastlane build_only 2>/dev/null || exec fastlane build_only
fi

echo "==> Regenerating Xcode project, archiving, uploading to TestFlight…"
bundle exec fastlane testflight 2>/dev/null || fastlane testflight
