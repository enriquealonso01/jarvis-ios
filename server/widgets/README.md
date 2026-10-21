# JARVIS home-screen widgets (server side)

Requirement 8: Enrique describes a widget in a chat, JARVIS designs it, and it appears on his
home screen. The app does the rendering; JARVIS only has to reply with a spec and, for live
numbers, keep a small JSON file current.

1. **Platform note (already shipped in the app, no deploy).** The app's
   `platform_hints.hermex.append` note (`HermesREST.platformNote`) now describes the
   ```` ```jarvis-widget ```` block and the data-file convention. App sessions only.

2. **This skill (needs deploy).** `jarvis-widgets/SKILL.md` is the fuller reference: the spec
   fields, the three styles, the data file, and how to keep it fresh with a cron job.

3. **The folder.** Data files live in `~/JARVIS-Files/widgets/` (the same folder the app's
   "Files from JARVIS" screen shows). The app refuses data paths outside `~/JARVIS-Files`.
   Create it once: `mkdir -p /root/JARVIS-Files/widgets`.

## Deploy (box, as root)

```bash
mkdir -p /root/JARVIS-Files/widgets
cp -r server/widgets/jarvis-widgets /root/.hermes/skills/
hermes skills list | grep jarvis-widgets
```

No restart needed: new app sessions pick the skill up.

## Verify

In the app, ask: "Make me a widget with today's Z.AI usage for both plans, refreshed every
30 minutes." The reply should show a widget preview with Add to Home Screen. Tap it, then
touch and hold the home screen, tap Edit > Add Widget > JARVIS. JARVIS should also have
created `~/JARVIS-Files/widgets/<id>.json` and a cron job that rewrites it; the widget picks up
new values whenever the app is opened.

## Limits (v1)

- The widget refreshes its live data when the app comes forward, not in the background.
- Specs are stored in the keychain group the app shares with its widget, so this works
  without the App Group capability.
