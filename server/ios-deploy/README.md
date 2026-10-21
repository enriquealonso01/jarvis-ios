# JARVIS changes and deploys the app from a chat (server side)

Requirement 10: JARVIS can change the app and deploy it (edit code, CI, TestFlight) from a chat.

The pipeline already exists in the repo: PR CI (`pr-ci.yml`) on every PR into v3, and the
TestFlight release (`ios-release.yml`, dispatched on `v3`, internal testing). Signing and App
Store Connect secrets stay in GitHub Actions; the box never holds them. What JARVIS needs is a
clone, a GitHub token that can push branches, open and merge PRs and dispatch workflows, and
the guarded helper and skill in this folder.

## One-time setup (Enrique)

1. Create a fine-grained GitHub token at https://github.com/settings/personal-access-tokens.
   Give it access to the `enriquealonso01/jarvis-ios` repository only, with these permissions:
   - Contents: read and write
   - Pull requests: read and write
   - Actions: read and write
   - Metadata: read

   Set an expiry you're comfortable with.
2. On the box, as root:

```bash
gh auth login --with-token   # paste the token, then press Ctrl-D
gh auth setup-git
git clone https://github.com/enriquealonso01/jarvis-ios /root/projects/jarvis-ios
install -m 0755 server/ios-deploy/jarvis-ios-ship/jarvis-ios-ship /usr/local/bin/jarvis-ios-ship
cp -r server/ios-deploy/jarvis-ios-ship /root/.hermes/skills/
jarvis-ios-ship status
```

Optional: protect `v3` on GitHub so that merging needs the PR CI check. Then even a wrong
`ship` can't merge red code.

## Guardrails (in the helper)

- Work happens only on `jarvis/*` branches cut from `origin/v3`, and PRs go only into `v3`.
- `ship` refuses to run without `--approved`, and refuses if the PR's checks aren't green.
  The skill tells JARVIS to pass `--approved` only after Enrique says yes in the chat.
- No force-push, no tags, no direct pushes to main, v2 or v3.

## Verify

In the app, ask JARVIS: "Change the empty Files from JARVIS text to say 'Nothing here yet.' and
ship it." JARVIS should open a PR, report green CI, ask before shipping, and after your yes
report a new TestFlight build number.
