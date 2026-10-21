---
name: jarvis-ios-ship
description: "Use when Enrique asks, in a chat, to change the JARVIS iPhone app itself (a fix, a tweak, a new screen) and get it onto his phone: edit the repo, open a PR, wait for CI, and after his approval ship it to TestFlight."
---

# Changing and shipping the JARVIS iPhone app from a chat

The app's source is `enriquealonso01/jarvis-ios` (public), cloned at `/root/projects/jarvis-ios`.
v3 is the SwiftUI app in `HermesMobile/`, built from branch `v3`. The `jarvis-ios-ship` helper
wraps every step and enforces the guardrails.

## Steps

1. `jarvis-ios-ship status`: check that the clone is clean and nothing of yours is still open.
2. `jarvis-ios-ship start <short-slug>`: makes a fresh branch `jarvis/<slug>` from `origin/v3`.
3. Make the change. Read the neighbouring code first and follow its style. Any new UI string
   needs an entry in `HermesMobile/Resources/Localizable.xcstrings` (CI checks it). A new
   Swift file must also be added to `HermesMobile.xcodeproj/project.pbxproj`; prefer editing
   existing files.
4. Commit: `git -c user.name="JARVIS (for Enrique Alonso)" -c user.email="exa8981@gmail.com" commit -am "<what and why>"`.
5. `jarvis-ios-ship pr "<title>" "<what changed, how to try it>"`: pushes the branch and opens a
   draft PR into v3.
6. `jarvis-ios-ship wait`: PR CI (build and unit tests, about 15 minutes). If it fails, read
   the failure with `gh run view <id> --repo enriquealonso01/jarvis-ios --log-failed`, fix it,
   commit, run `pr` again, then `wait`.
7. Ask Enrique, with a buttonGroup block if you're in the app: what changed, the PR link, the
   green checks, and "Ship to TestFlight?". **Wait for his yes.**
8. Only after his yes: `jarvis-ios-ship ship --approved`. This merges the PR into v3 and
   dispatches the TestFlight release.
9. About 30-40 minutes later, run `jarvis-ios-ship release-status`. Tell him the build number
   and what to try on his phone.

## Rules

- Never pass `--approved` without Enrique's explicit yes in this conversation for this PR.
- Never push to main, v2, v3 or any branch outside `jarvis/*`. Never force-push, tag or
  delete branches.
- Never put secrets, tokens, passwords or personal data in the repo (it is public).
- Keep each change small and reviewable; one PR per request.
- If the request is risky (sign-in, calls, push, entitlements, the release pipeline), say so
  and suggest leaving it to a Claude Code session instead.
