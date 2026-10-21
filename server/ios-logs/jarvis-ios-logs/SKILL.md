---
name: jarvis-ios-logs
description: "Use when something in the JARVIS iPhone app misbehaves (sign-in, chat, calls, voice, push, widgets, files) or Enrique asks what the app did: read the app's and the server's logs for it."
---

# Reading the JARVIS iPhone app's logs

Everything that touches the app, read-only, in one command:

```bash
jarvis-ios-logs                      # last 2 hours, every section
jarvis-ios-logs --since 30m --errors # only the failures
jarvis-ios-logs --section app        # app | hermes | caddy | services
```

| section | what it is |
|---|---|
| `app` | The phone's own failure log, `~/.jarvis-ios/logs/<YYYY-MM-DD>.jsonl`: requests the host refused or never answered (`cat: http`, with the route's path and the reason), failed calls (`call`), failed VoIP registration (`push`). The app uploads it when it comes forward or goes to the background, so the newest failures may arrive a little later. |
| `hermes` | `~/.hermes/logs/{agent,errors,gui,dashboard-auth}.log`: sign-ins, WebSocket and REST errors, event-loop stalls. |
| `caddy` | The reverse proxy's access log for the app: requests with User-Agent `JARVIS-iOS/<version> (<build>; iOS ...)` and the `/bridge`, `/voice-gw`, `/v1/` routes, with status and duration. |
| `services` | journald for the push bridge, voice gateway and v2 chat adapter units (found by name). |

## How to use it

1. Ask Enrique roughly when it happened, or use `--since`.
2. Run with `--errors` first, then without it around the time of the first failure.
3. Match the app's entry (time, path) with the server's line for the same request.
4. Report what failed, where (app, proxy, Hermes, bridge, voice gateway), and the likely cause. Quote short log lines; never paste tokens, cookies or full request bodies.

## Rules

- Read only. Never restart services, edit configs or delete logs from this skill; propose the
  fix and ask.
- The app's log holds no tokens or message text, only paths and short reasons. Keep it that way
  in anything you write back.
