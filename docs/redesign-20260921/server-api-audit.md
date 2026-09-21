# JARVIS Server API Audit — iOS App Redesign

**Date:** 2026-09-21 · **Host:** jarvis.enriquecodes.com (Caddy → local services) · **Mode:** read-only live tests, all status codes from real requests
**Credentials:** dashboard basic provider user `jarvis`, password `<redacted>` (config: `/root/.hermes/config.yaml` → `dashboard.basic_auth.*`; live pw copy used for tests at `/root/.hermes/jarvis/.dash_pw_tmp`). All secrets below are `<redacted>`.

---

## 1. Topology correction (important)

The routing brief was partly wrong. Live-verified against `/etc/caddy/Caddyfile` + `systemctl` + `ss -tlnp`:

| Public path | Upstream | Service |
|---|---|---|
| `/` (default) and **`/auth/*`, `/api/*`** | 127.0.0.1:9119 | **hermes-dashboard** (`hermes dashboard --port 9119`) — this is where ALL auth + session APIs live |
| `/bridge/*` (prefix **stripped** by `handle_path`) | 127.0.0.1:9160 | jarvis-ios-bridge (push/schedule/feedback) — public paths are `/bridge/health`, `/bridge/register`, … |
| `/voice-gw/*` (prefix kept) | 127.0.0.1:9150 | JARVIS Voice Gateway (WebRTC) |
| `/k/*`, `/keys-drop/*` | 127.0.0.1:8777 | keys-drop one-time secret page (**not** auth) |
| `/plaid-link*` | 127.0.0.1:3001 | home_finances Plaid Link (not iOS-relevant) |

Port 8777 is **keys-drop**, not an auth service. `POST /auth/password-login` is served by the dashboard on 9119.

---

## 2. Auth / PKCE native flow — ✅ ALL WORK (end-to-end proven live)

### GET /auth/native/authorize — **200**
```
GET /auth/native/authorize?provider=basic&code_challenge=<S256>&code_challenge_method=S256&redirect_uri=http://127.0.0.1:8619/cb&state=<state>&client_id=jarvis-ios
→ 200 (302→/login shape for browsers; for the native flow it registers the pending PKCE authorization)
```
Negative: `redirect_uri=https://...` → **400** `{"detail":"native redirect_uri must be http:// on the loopback interface"}` (localhost is rejected too — RFC 8252 §8.3; use literal `127.0.0.1`).

### POST /auth/password-login — **200** (cookie-less PKCE fallback VERIFIED)
```
POST /auth/password-login
{"provider":"basic","username":"jarvis","password":"<redacted>",
 "code_challenge":"<S256>","redirect_uri":"http://127.0.0.1:8619/cb","state":"audit-state-1"}
→ 200 {"ok":true,"next":"http://127.0.0.1:8619/cb?code=<code>&state=audit-state-1"}
```
This is the critical iOS path: no cookie jar needed; the server re-registers the pending authorization from the body params and returns a one-time code in `next`. No session cookies are set on this branch.
Negative shapes:
- missing fields → **422** `{"detail":[{"type":"missing","loc":["body","provider"],"msg":"Field required",...}]}`
- bad password → **401** `{"detail":"Invalid credentials"}` (generic, no user oracle)
- brute-force throttle: **429** after 10 attempts / 60 s per IP

### POST /auth/native/token — **200**
```
POST /auth/native/token
{"grant_type":"authorization_code","code":"<code>","code_verifier":"<verifier>","redirect_uri":"http://127.0.0.1:8619/cb","client_id":"jarvis-ios"}
→ 200 {"access_token":"<redacted>","refresh_token":"<redacted>","expires_at":<unix>,"provider":"basic","token_type":"...","user_id":"jarvis"}
```

### POST /auth/native/refresh — **200**
```
{"grant_type":"refresh_token","refresh_token":"<redacted>"} → 200 (same key set, tokens rotated — verified live)
```
Bogus token → **401** `{"error":"session_expired","detail":"Refresh token expired or invalid; start a new sign-in."}`

### Token usage everywhere: `Authorization: Bearer <access_token>`
The dashboard HMAC access token works cookie-less on the dashboard, the voice gateway (verified locally against the shared signing secret), and the iOS bridge (dual auth: Bearer or HMAC body sig). Verified live on all three services.

Other auth endpoints:
- `GET /api/auth/providers` — **200** (public) `[{"name":"basic","display_name":"Username & Password","supports_password":true}]`
- `GET /api/auth/me` — **200** `{"user_id":"jarvis","email":"","display_name":"jarvis","org_id":"","provider":"basic","expires_at":<unix>}`; no auth → **401** `{"error":"unauthenticated","detail":"Unauthorized","reason":"no_cookie","login_url":"/login"}`
- `POST /api/auth/ws-ticket` — **200** `{"ticket":"<redacted>","ttl_seconds":30}` (for WebSocket auth)
- `POST /auth/logout`, `GET /login`, `GET /auth/login`, `GET /auth/callback` — exist (browser-oriented; not exercised)

**`login_works: true`** — full authorize → password-login (cookieless) → token → refresh chain returned 200 at every step.

---

## 3. Sessions / transcripts (dashboard, Bearer auth) — ✅ WORK

| Endpoint | Live result |
|---|---|
| `GET /api/sessions?limit=N` | **200** `{"sessions":[{id, source, user_id, session_key, chat_id, display_name, origin_json, ...}]}` |
| `GET /api/sessions/stats` | **200** `{"total":1288,"active_store":1288,"archived":0,"messages":71715,"by_source":{"cron":998,"cli":188,"whatsapp":5,"signal":3,"acp":2,"discord":1}}` |
| `GET /api/sessions/search?q=test&limit=2` | **200** `{"results":[{"snippet":"...>>>test<<<..."}]}` (query highlighting) |
| `GET /api/sessions/{id}` | **200** full session object; unknown id → **404** `{"detail":"Session not found"}` |
| `GET /api/sessions/{id}/messages?limit=2` | **200** `{"session_id":"...","messages":[...],"pagination":{"limit":500,"offset":0,"order":"latest","returned":N}}` |
| `GET /api/sessions/{id}/export?format=json` | **200** full transcript export |
| `GET /api/sessions/empty/count` | **200** `{"count":0}` |

Message objects **include tool calls**: observed keys (live): `role, content, timestamp, tool_calls, tool_call_id, tool_name, reasoning, reasoning_content, reasoning_details, api_content, token_count, finish_reason, display_kind, display_metadata, compacted, ...`. LLM text, tool calls and reasoning are all present — sufficient for a transcript UI.

Pagination: `limit` (max 500/page), `offset`, `order=oldest|latest`, `include_compacted`. `POST /api/sessions/bulk-delete`, `/import`, `/prune`, `PATCH /api/sessions/{id}` (rename), `DELETE /api/sessions/{id}` exist but were deliberately NOT tested (destructive).

---

## 4. iOS bridge (push / calls / feedback) — ✅ WORK (auth: Bearer or HMAC)

Public paths after Caddy prefix-strip (`/bridge/X` → service `/X`):

| Endpoint | Live result |
|---|---|
| `GET /bridge/health` | **200** `{"ok":true,"apns_configured":true,"device_registered":false,"last_push_error":"403 InvalidProviderToken at 1789994187","push_ok":0,"push_fail":2,"scheduled":0,"dropped_calls":0}` |
| `GET /bridge/schedule/list` | **200** `{"scheduled":[],"dropped":[]}` (no HMAC sig → **401** `{"detail":"bad signature"}`; dashboard Bearer accepted) |
| `POST /bridge/register` | validation probe `{"device_token":"abcd1234"}` → **400** `{"detail":"device_token too short — PushKit tokens are 64 hex chars (32 bytes); refusing to overwrite a working registration"}` (success path not exercised — would overwrite live DEVICE_TOKEN) |
| `POST /bridge/feedback` | validation probe `{}` → **400** `{"detail":"feedback needs a session_id and/or text"}`; accepts `{session_id?, category?, text?, message_id?}` → `{ok,id,notified}` (not exercised to avoid polluting the feed) |
| `GET /bridge/feedback/list` | **200** `{"items":[{id,ts,session_id,message_id,category,text}],"total":1}` |
| `POST /bridge/call`, `POST /bridge/schedule`, `POST /bridge/schedule/cancel`, `/bridge/secrets*` | exist (destructive; not tested) |

⚠️ **Operational flag:** `last_push_error: 403 InvalidProviderToken` — APNs auth is currently broken (key/team mismatch). Push registration works at the API layer, but deliveries will fail until the APNs credential is fixed.

---

## 5. Voice gateway — ✅ WORK (Bearer auth)

| Endpoint | Live result |
|---|---|
| `GET /voice-gw/healthz` | **200** `{"ok":true,"uptime_s":227910.7,"brain":"openai-realtime","realtime":true,"openai_status":"ok",...}` |
| `GET /voice-gw/api/metrics` | **200** per-surface turn latency stats |
| `GET /voice-gw/api/diag` | **200** network diagnostics |
| `GET /voice-gw/api/sessions` | **200** live WebRTC sessions (shows `surface:"ios"` entries) |
| `POST /voice-gw/api/offer` (also `/webrtc/offer`) | not exercised (needs live SDP offer) — route exists |
| `POST /voice-gw/api/say` `{"text":"audit test"}` | **404** `{"detail":"no live session"}` (correct behavior with no active call) |
| `POST /voice-gw/api/hangup`, `/voice-gw/api/discord/*` | exist (not tested) |

No-auth probe → **401** `{"error":"unauthorized"}`. Same dashboard Bearer accepted.

---

## 6. Dashboard control-plane (bonus, useful for the app)

- `GET /api/control/overview` — **200** (projects list, connectors, PC-bridge status, attention items; slow: 8-25 s)
- `GET /api/control/voice/transcripts?limit=2` — **200** live voice conversation turns
- `GET /api/control/voice/status` — **200** `{"tts_ready":true,"voice_id":"<redacted>","model":"glm-5.3-flash",...}`
- `GET /api/control/bridge/status` — **200** Windows PC bridge state
- `GET /api/control/activity`, `/api/control/automations`, `/api/control/projects` — exist (`/projects` timed out >15 s in tests; the PC bridge makes it slow)
- Plus voice turn endpoints (`/api/control/voice/converse|tts|transcribe|turn|events/{id}|poll/{id}`) and SSE at `/api/control/voice/events/*` (Caddy flush_interval -1)

---

## 7. What is MISSING / needs work for the new iOS app

1. **No sessions-grouped-by-project/topic endpoint.** `GET /api/sessions` returns a flat list with `display_name` only; `GET /api/control/projects` is a *dev-repo* list (from the Windows PC bridge), not a grouping of agent sessions. The app needs either a `group_by` param on `/api/sessions` or a `/api/sessions/groups` endpoint (by `source`, `project`, or `display_name` topic).
2. **No dashboard-namespace feedback endpoint.** `GET/POST /api/feedback` → 404/405. Feedback exists only on the iOS bridge (`POST /bridge/feedback`, `GET /bridge/feedback/list`). Fine if the app targets the bridge, but the dashboard API surface has none.
3. **APNs push currently broken at the provider level:** `last_push_error: 403 InvalidProviderToken` on `/bridge/health`; `push_fail: 2`. API contract is fine; the APNs signing key/team config needs fixing before TestFlight VoIP pushes work.
4. **`GET /api/control/projects` latency** (15-25 s via PC bridge) — unusable for a mobile cold-start; needs caching or a timeout-bounded variant.
5. **Minor:** no batch transcript endpoint (must paginate per session); no public OpenAPI schema (the dashboard 302-redirects `/openapi.json` behind auth, and the route set is spread across `web_routers/*`).
6. **Nothing missing on auth:** the cookie-less PKCE password-login fallback works exactly as designed for URLSession.

## 8. Security notes (observed, unchanged)

- Redirect_uri validated to loopback http; provider equality enforced on the native branch; constant-time password verify; 429 rate limit (10/min/IP) on password-login; generic 401s (no user oracle); device-token format guards on `/register`; `device_token` stripped from `/schedule/list` responses. No changes made to any service.
