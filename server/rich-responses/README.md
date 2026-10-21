# JARVIS rich responses (server side)

The JARVIS iPhone app (v3) renders `jarvis-rich` blocks (requirement 5). Two pieces make
JARVIS emit them:

1. **Platform note (already shipped in the app, no deploy).** Hermex keeps a per-Profile
   `platform_hints.hermex.append` note that Hermes appends to the system prompt of app sessions
   only (source `hermex`). The v3 app's note (`HermesREST.platformNote`) now names the app as
   JARVIS and describes the block format. The app writes it with `PUT /api/config` (deep merge,
   that one key) the first time it signs in after an update, per Profile. Nothing else in the
   config changes, and other surfaces never see it.

2. **This skill (needs deploy).** `jarvis-rich-responses/SKILL.md` is the fuller reference with
   the table of props and the rules (real data only, https only, app sessions only).

## Deploy (box, as root)

```bash
cp -r server/rich-responses/jarvis-rich-responses /root/.hermes/skills/
# Skills are read when an agent is built; new app sessions pick it up. No restart needed.
hermes skills list | grep jarvis-rich-responses
```

Optionally enable it only for the profiles the app uses (`default`, `coder`).

## Verify

Open the app, start a session, and ask: "Give me a poll with three lunch options" or "Chart my
Z.AI usage for the last 5 days as a bar chart". The reply should render a native poll / chart
with a data table, not JSON. A tapped option comes back as your next message.
