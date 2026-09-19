# ARCHITECTURE

One JARVIS box (NetCup vServer) serves everything. Enrique's iPhone talks to it
over the public Caddy host; agents talk over loopback with HMAC.

```
iPhone (TestFlight app, com.enriquecodes.jarvis)
  │  HTTPS (Bearer = dashboard access token in Keychain)
  ▼
Caddy  jarvis.enriquecodes.com
  ├── /bridge/*      → 127.0.0.1:9160  (prefix stripped)   push bridge
  ├── /voice-gw/*    → 127.0.0.1:9150                      voice gateway
  └── /*             → hermes-dashboard (CC web/API, auth)
```

## Components

### iOS app (`ios/`, SwiftUI, iOS 18+ target, dark-only)
- **Auth** (`AuthStore.swift`): RFC 8252 native PKCE against the dashboard
  `basic` provider → stateless HMAC access token (+ refresh) in Keychain.
  This SAME bearer authorizes the bridge and the gateway's WebRTC offer.
- **Home** (`HomeView.swift`): CC vitals/LLM usage/crons/current work via the
  dashboard control-center API (same shapes as the web CC).
- **Chats** (`ChatsView.swift`): dispatch board projects → thread history →
  send via the dashboard agent chat endpoint.
- **Secrets** (`SecretsView.swift`): named-secret manager; values live ONLY in
  `/opt/jarvis-ios-bridge/secrets.json` (0600) server-side; UI shows masked
  previews. Optional Face ID gate.
- **Calls** (`CallManager.swift`, `WebRTCClient.swift`, `CallsView.swift`):
  PushKit → CallKit full-screen; answering opens a WebRTC audio offer/answer
  with the voice gateway (`POST {voice-gw}/api/offer`, Bearer). "Call me"
  button POSTs bridge `/call`; scheduled list/cancel against `/schedule/*`.

### Push bridge (`server/push_bridge/main.py`, systemd `jarvis-ios-bridge`, :9160)
FastAPI. Serves from the repo checkout
(`WorkingDirectory=/root/projects/jarvis-ios/server/push_bridge`): a repo edit
IS the deploy after a restart; last-known-good copy lives in
`/opt/jarvis-ios-bridge-lkg/`. State dir `/opt/jarvis-ios-bridge/`
(shared_secret, apns.env, apns.key, scheduled_calls.json, secrets.json,
push_counters.json — all root-only 0600). Auth ladder on every
route: `x-bridge-sig` HMAC-SHA256(secret, raw body) **or** dashboard Bearer
(gateway-identical verify: sig + kind=access + exp, checked locally).
- `/call` → APNs VoIP push (payload: reason, call_id, gateway_ws:"/voice-gw").
  `apns-topic` MUST equal the app bundle ID (com.enriquecodes.jarvis); when the
  p8 isn't installed it logs-and-acks (`pushed:false`) so agents can develop.
  Any APNs non-200 is logged LOUD (`[bridge] APNs push REJECTED: HTTP <code>
  <reason>`) — a rejected push must never masquerade as "no device yet".
- `/schedule`, `/schedule/list`, `/schedule/cancel` → scheduler loop (20s tick)
  fires `/call` when due; device_token snapshotted at schedule time
  (server-side only — /schedule/list strips it from responses).
- `/register` → app POSTs its APNs token on launch; persisted to apns.env and
  auto-injected into every push.
- `/secrets`, `/secrets/set`, `/secrets/delete` → named-secret store.
Deployed code = repo working tree (systemd WorkingDirectory points here);
restarts only after `py_compile` passes + `/health` verified. Three copies
exist by design — repo (serving), `/opt/jarvis-ios-bridge-lkg/main.py`
(rollback), and the running process — and they are pinned equal by
`scripts/check_deploy_parity.py` (verify_all step 5b-bis): unit must point
at the repo, LKG must be byte-identical to the repo, and live `/health` must
expose `push_ok` (a newest-code capability marker) so a stale running copy
fails loudly. NO other copy of main.py may exist (the setup-era
`/opt/jarvis-ios-bridge/main.py` — three commits behind, loaded by nothing —
created a "prod is stale" phantom that cost the 2026-09-19 15:30 audit; it
was removed, byte-identical to commit 40daafe).

### Voice gateway (`/opt/voice-gw/gateway.py`, systemd `jarvis-voice-gateway`, :9150)
Same Pipecat pipeline for every surface (web orb, PWA, native app):
WebRTC offer/answer at `/api/offer` (auth: dashboard cookie OR Bearer access
token — added 2026-09-18 for native clients), `/api/say`, `/api/hangup`,
`/healthz`. The iOS payload field `gateway_ws:"/voice-gw"` tells the app which
public path prefixes to use. Repo copies `server/voice_gateway/gateway.py` +
`server/voice_gateway/session.py` are synced mirrors for traceability; edits
go through py_compile gate + restart + healthz verify (last-known-good
snapshot kept). On a mid-call pipeline crash, `VoiceSession._run()` pushes
`{type:"state", state:"error", label}` over the app data channel before
closing (added 2026-09-18) — the iOS app turns that into CallKit call-ended +
a "failed" call-log stamp instead of dead air.

Native-client specifics (added 2026-09-18, build-loop audit): the iOS app
sends `request_data: {surface: "ios", reason}` in its offer body. The gateway
labels the session surface `ios` (metrics/CC show it distinctly from
`cc_pwa`) and, if a `reason` is present, injects it ~6s after connect as a
spoken line so JARVIS opens the call with why he's calling. The app ALSO
creates the SmallWebRTC "app" data channel (label `app`, ordered) and sends a
literal `ping` TEXT string every second — same contract as voice_page.html.
TEXT is load-bearing: pipecat's keepalive counts only str frames starting
with "ping" (`isinstance(message, str)`); a binary ping is missed by the
liveness clock and error-logged per second (build 29 shipped isBinary:true —
fixed 2026-09-19, pinned in swift_sanity). The
gateway pushes `hello` / `state` / `transcript` / `metrics` JSON back over it;
`WebRTCClient.onAppMessage` routes those into `CallManager` (call-state label
+ last transcript on the Calls tab). A native call without the data channel
would look dead to the session monitor and get no live state — don't remove it.

### Dashboard (hermes-dashboard)
Serves the CC web UI + the API the app mirrors (vitals, dispatch, auth/native
PKCE endpoints). Agents never restart it unless a router file compiles AND
/control + healthz are verified after.

### Watch-of-the-watch (jarvis-ios-watch-sentinel)
No-LLM cron (30m, `/root/.hermes/scripts/jarvis_ios_watch_sentinel.sh`, mirror
in `scripts/`) that guards the device-watch — after the build-loop sunset the
15m watch is the mission's ONLY autonomous announcer, so its death must not be
silent. Checks: watch cron exists + enabled, ticks fresh (last_run_at < 40m),
tick budget > 8, bridge /health reachable, probe still emits a VERDICT. When
the watch cron is GONE, /health ARBITRATES: `device_registered:true` AND
`push_ok>=1` (the exact shape the MISSION-COMPLETE endgame leaves behind) is a
QUIET stand-down — success must never page as a loss; any lesser health with
the bridge answering means the announcer was truly lost and fires ONE latched
SENTINEL line to the TF Ops group (failure channel suppressed — the script
always exits 0); it is strictly observe-and-report and never mutates hermes
state. Contract pinned in check_watch_sentinel.py (wiring) +
check_watch_sentinel_behavior.py (sandbox behavior) + check_doc_contracts.py
step 10; verify_all 5c-bis runs both on every sweep.

## Call flow (the core mission)
1. Any agent (WhatsApp/voice/loop) HMAC-POSTs `/call {reason}` (or `/schedule`).
2. Bridge signs ES256 JWT with the APNs p8 → VoIP push to the registered
   device token, payload `{reason, call_id, gateway_ws}`.
3. iOS PushKit wakes the app (even killed/locked) → CallKit incoming screen.
4. On answer, `WebRTCClient` POSTs an audio offer to
   `https://jarvis.enriquecodes.com/voice-gw/api/offer` with the Keychain
   bearer → gateway answers → JARVIS speaks with the reason as context.

## Verifying the native path (no phone needed)
`scripts/verify_all.sh` step 6/6 runs `scripts/probe_webrtc_native.py`: a real
aiortc WebRTC client (venv `/root/venvs/webrtc-probe`, aiortc + pyyaml) mints a
dashboard Bearer, POSTs an offer with `request_data {surface:"ios", reason}` to
the LIVE gateway, connects ICE, opens the `app` data channel, pings at 1 Hz,
and asserts the gateway's audio track + `hello` arrive — the exact contract
the iOS `WebRTCClient` implements. It hangs its throwaway session up at the
end and is read-only otherwise. If the probe ever FAILs after a gateway
change, the native call path is broken regardless of what the auth-gate check
(step 3) says.

## Contract checkers (the app's every network surface, pinned)
verify_all.sh steps 1d–1h pin each layer of the app↔box conversation so a
dashboard/bridge rename, dropped field, or moved guard fails the sweep before
it ships in a build:
- **1d login** (`check_login_contract.py`): the RFC 8252 PKCE sign-in round
  trip against the live dashboard (authorize 302 + cookie, brokered password
  login shape, loopback-redirect boundary).
- **1e CC reads** (`check_cc_contract.py`): the seven Home/Chats GETs decode
  into the app's exact Swift models — top-level fields AND (1e-bis) every
  collection ELEMENT struct (`Overview.Bridge/Project`, `ZaiUsage.Window`,
  `Automations.Item`, `Activity.Session`, `Attention.Alert`, ChatsView's
  `Board.Thread/Item`) pinned OFFLINE in both directions (req = non-optional,
  opt = `T?`), closing the element blind spot 1f called out; selftest 7/7 on
  tmp copies.
- **1f bridge** (`check_bridge_contract.py`): all eight Secrets/Calls routes
  on the push bridge, decode + req/opt split both directions. Since
  2026-09-19 (1f-bis) also pins the POST /schedule at_iso VALIDATION
  GUARDS offline (three needles: parse-reject + both 400 details) and
  LIVE (real 400s + pinned details probed against a throwaway instance —
  garbage/past at_iso must be refused BEFORE persistence, because the
  scheduler fires persisted entries the moment they are due: a past
  timestamp would ring Enrique instantly, a garbage one would sit
  silent-never); since 2026-09-19 (1f-ter) likewise the POST /register
  device_token FORMAT GUARDS (offline needles + live 400s for
  short/non-hex tokens on both auth paths) — a malformed token persisted
  over the real one silently kills every future push while
  `device_registered` stays true; since 2026-09-19 (1g-bis) likewise the
  REASON TEXT-SIZE GUARDS on POST /call + POST /schedule (offline needles +
  live 400s: /call#empty /call#huge /schedule#huge) — the reason rides
  INSIDE the APNs payload, Apple 413s payloads over 4096 bytes, so an
  oversized /schedule entry persisted fine and then silently dropped after
  10 fire-time retries (1f-bis's silent-never class via payload SIZE);
  since 2026-09-19 (1j) likewise the CANCEL GUARDS on POST /schedule/cancel
  (offline needles + live 400/404s: #unconfirmed-all #nonstring #blank-id)
  — the empty body was the bridge's one IRREVERSIBLE write (wipes every
  pending call; the scheduler has no undo) and demanded zero friction, so
  cancel-all now requires `{"confirm": true}`, a whitespace-only call_id
  404s instead of masquerading as an id-targeted cancel, an unmatchable id
  404s loudly (was silent `cancelled: 0`), and a non-string call_id 400s
  BEFORE pydantic v2 would raise an opaque 500; the agent CLI mirrors the
  gate (`cancel --yes` for cancel-all); selftest 27/27.
- **1g chat send** (`check_chat_contract.py`): the app's WRITE path —
  POST `/api/control/work/{id}/chat`, POST `/api/control/project/task`, GET
  `/api/control/work/{id}/history` — routes, Swift models, AND the pre-LLM
  400 guards (`detail="empty message"` / `"empty task"`) which sit BEFORE
  `_run_jarvis_turn`; the live layer therefore proves the guards answer 400
  `{detail}` with zero model calls, plus a non-vacuous history element shadow
  against a real session.
- **1h push payload** (`check_push_payload_contract.py`): the ONE
  Apple-boundary object the HTTP checkers cannot see — the VoIP push payload
  `_send_voip` serializes (`{"aps": {}, **payload}`) and
  `handleVoIPPayload` reads. Offline: SET-equality between the keys every
  bridge fire site builds (/call handler + scheduler tick) and the keys the
  app reads, the top-level `aps` envelope, the literal `"/voice-gw"` value,
  the Swift `VoIPPayload` req/opt split, single-reader placement (every
  `payload[...]` read must sit inside `handleVoIPPayload`), and the
  redelivery guard's `callID` dedupe key. Live: the REAL `_send_voip` runs
  in-process (stubbed httpx/jwt capture the serialized body — no network, no
  Apple, no live bridge touched) for the direct /call path AND a real due
  scheduler tick; each captured wire body decodes against the app's exact
  read shape (required keys present+String, `scheduled_by` nullable), the
  early-exit paths provably capture nothing, and a drift of the pin (the
  literal key SET) fails until consciously re-pinned. This is the check that
  keeps the silent-fallback class impossible: a bridge key rename would
  otherwise be masked by the app's `?? "JARVIS call"` / `?? "/voice-gw"`
  defaults — the phone rings, nothing errors, the reason is just blank.
  Since 2026-09-19 (1g-bis) the `aps`-envelope needles anchor the closing
  `)` of the real `c.post(...)` statement: a bare-literal needle let a
  COMMENT quoting the idiom (the new 1g guard comment in `_send_voip`) mask
  a real vanish — T4's tamper read green until the anchor landed.

## The ship gate (step 8: a run can't end believing a lie about shipping)
Step 7 (parity) proves nothing is unpushed; step 8 proves the thing that WAS
pushed actually shipped. `ship_gate.py` walks the real chain fail-closed:
latest local `ios-v*` tag exists on origin (hop 1 — the 12:05 failure class:
a fix committed locally, never pushed, no tag, "rides the next build" with no
vehicle) → the tag's `ios-release` Actions run concluded success (hop 2;
anonymous GitHub API is 404, so auth comes from git's own credential store —
never printed) → ASC shows that run's build number VALID (hop 3a; the
workflow stamps CFBundleVersion = run number) with internalBuildState
IN_BETA_TESTING (hop 3b). Any hop missing, red, or lagging (run in flight,
ASC ingest delay with a 3×20s retry) FAILS the sweep loudly — a run that
can't prove "shipped" says so instead of assuming. Negative-tested by
`selftest_ship_gate.sh` in throwaway clones (real tree untouched): T1
local-only tag, T3 a RED run for the latest tag (real historical data:
ios-v26 = run 28 concluded failure), T4 missing git credentials (loud config
failure, no traceback — which the selftest caught as a real gate bug on its
first authoring run).

## What only Enrique can do (the gated ladder)
Xcode build on the Mac → TestFlight upload (fastlane lane or manual) → create
the APNs p8 key and hand it over for install. See docs/BUILD.md, FASTLANE.md,
API.md "Pending".
