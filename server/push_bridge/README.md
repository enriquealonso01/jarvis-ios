# JARVIS push bridge (server side)

The FastAPI service behind `https://jarvis.enriquecodes.com/bridge/*` (systemd `jarvis-ios-bridge`,
127.0.0.1:9160): VoIP pushes and scheduled calls, device registration, named secrets, in-app
feedback, and since 2026-10-22 **Bot routing** (`POST /route`).

Auth is dual on every endpoint: an agent's `x-bridge-sig` HMAC, or the app's dashboard Bearer
(the native access token `JarvisVoiceAuth` mints from the saved sign-in).

## `POST /route` (Bot routing)

Body `{"text": "<the first message of a new chat>", "profile": "default"}`. Runs the box's
`/usr/local/bin/jarvis-route` (the profile router in `~/.hermes/dispatcher/profile_router.py`)
and answers `{"profile": "ios" | "general", "confidence": 0.95, "reason": "…", "title": "iOS Builder" | null}`.
The app moves a new general chat into the named Bot when the confidence is at least 0.7
(`JarvisBotRouting`); 503 or a slow answer leaves the chat general.

## Deploy (box, as root)

The service runs from its own checkout of this repo, so the app checkout can move between
branches without taking the bridge down:

```bash
cd /root/projects/jarvis-ios-bridge && git fetch -q origin && git checkout -q --detach origin/v3
systemctl restart jarvis-ios-bridge && curl -s 127.0.0.1:9160/health
```

`WorkingDirectory=/root/projects/jarvis-ios-bridge/server/push_bridge` in the unit; state stays
in `/opt/jarvis-ios-bridge/` (`apns.env`, `shared_secret`, counters, schedule). The unit file
here is the reference copy.
