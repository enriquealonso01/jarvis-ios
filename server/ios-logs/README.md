# JARVIS reads the iOS app's logs (server side)

Requirement 9: JARVIS can read all backend logs for the iOS app (app and server traffic, push,
voice, errors).

What the app does (shipped in the app, no deploy):

- Every Hermes request carries `User-Agent: JARVIS-iOS/<version> (<build>; iOS <version>)`, so
  the proxy's access log can pick out the app's traffic.
- The app keeps a log of its failures (requests the host refused or never answered, failed
  calls, failed VoIP registration), with paths and short reasons only, never tokens, queries
  or bodies. When it comes forward or goes to the background it writes the day's entries to
  `~/.jarvis-ios/logs/<YYYY-MM-DD>.jsonl` on the host through `POST /api/fs/write-text`
  (creating the folder once with `POST /api/files/mkdir`).

What needs deploying:

- `jarvis-ios-logs/jarvis-ios-logs`: a read-only script that prints the app's log, Hermes's
  logs, the Caddy access lines for the app and journald for the bridge and voice units.
- `jarvis-ios-logs/SKILL.md`: tells JARVIS when and how to use it.

## Deploy (box, as root)

```bash
install -m 0755 server/ios-logs/jarvis-ios-logs/jarvis-ios-logs /usr/local/bin/jarvis-ios-logs
cp -r server/ios-logs/jarvis-ios-logs /root/.hermes/skills/
jarvis-ios-logs --since 1h --errors   # smoke test
```

The script finds the Caddy log from `output file` lines in `/etc/caddy/Caddyfile`, or falls
back to `journalctl -u caddy`. If the access log isn't in JSON, the `caddy` section prints
nothing useful. In that case, add to the site block (a Caddy config change, for you to decide):

```
log {
    output file /var/log/caddy/jarvis-access.log
    format json
}
```

## Verify

Turn on airplane mode, open the app, try to send a message, turn airplane mode off and
bring the app back. Then ask JARVIS in a chat "what failed in the app in the last 10 minutes?"
It should find the `http` entries in the `app` section.
