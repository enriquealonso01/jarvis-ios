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

## Approvals (human in the loop, since 2026-11-12)

An agent files a decision for Enrique, he answers on the app's Approvals page, the system runs the
approved action and wakes the agent. The store and every rule live in the box CLI
`/usr/local/bin/jarvis-approval` (JARVIS-V2 `services/approvals`, `docs/approvals.md`); the bridge
is only transport. These four routes are the exception to "auth is dual":

| Route | Who | What |
|---|---|---|
| `GET /approvals` | app Bearer or agent HMAC | `{count, pending[], recent[], key_fingerprint, alert_registered}` |
| `POST /approvals/{id}/decision` | **app only** | `{decision: approve\|deny\|retry, signature, exp, input?, note?}`; 403 bad signature, 409 already answered otherwise, 422 invalid input |
| `POST /approvals/register` | **app only** | `{alert_token?, signing_key?}`: the APNs alert token and the phone's Ed25519 public key |
| `POST /approvals/notify` | **agent HMAC only** | `{event: new\|outcome\|wake_failed\|badge, title?, body?, badge, id?}` sends an alert push |

The answer is signed on the phone (Ed25519 over `jarvis-approval-v1`, id, type, subject, decision,
sha256 of the input or `-`, expiry; one per line) and verified by the CLI, so an agent's HMAC can
never answer for him. Pasted input goes to the CLI on stdin. Alert pushes use the same APNs key as
the VoIP ones on the app's own topic; the token is `ALERT_DEVICE_TOKEN` in `apns.env`.
Tests: `python -m pytest server/push_bridge -q`.

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
