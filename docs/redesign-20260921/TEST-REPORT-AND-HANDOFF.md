# JARVIS iOS v2 — Self-Test Report & Handoff

**Date:** 2026-09-21 · **Builder:** iOS v2 build agent (day run)
**Scope:** sessions-first redesign of `enriquealonso01/jarvis-ios`, rebuilt IN PLACE (bundle `com.enriquecodes.jarvis`, ASC app 6813590605, same CI/match/secrets), per Enrique's mid-run course correction.
**Status: TestFlight build 37 VALID and processing** — first redesigned build shipped.

---

## 1. What shipped (all commits `dea8d94..202de32`, on `main`)

### New app UI (replaces Home/Chats control-center layout)
| File | Role |
|---|---|
| `ios/JarvisApp/SessionsView.swift` | Sessions-first home: `GET /api/sessions?order=recent&limit=100` (dashboard, Bearer), grouped by project (`cwd` last component) or source; search filter; live dot; message/tool counts; relative times. |
| `ios/JarvisApp/TranscriptView.swift` | Claude-Code-style transcript: `GET /api/sessions/{id}/messages?order=oldest&limit=500`. Assistant text prominent, user bubbles; ALL tool calls/results collapsed into one "N tool activities" pill per turn, expandable to per-call name + summary + output. `tool_calls` accepted as JSON string OR array (flexible Codable). Toolbar: flag (feedback) + call-me-back. |
| `ios/JarvisApp/FeedbackSheet.swift` | In-session "something is not going correctly": category + details → `POST <bridgeBase>/feedback` (bridge; Caddy strips `/bridge`). |
| `ios/JarvisApp/CallMeSheet.swift` | "Call me back": instant (`POST /call`) or scheduled 15m/1h/evening (`POST /schedule`, ISO-8601) with reason; honest handling of `pushed=false` (APNs key gap surfaced in UI). |
| `ios/JarvisApp/MoreView.swift` | Capability-pack list + Secrets + Settings. |
| `ios/JarvisApp/CapabilityPacks.swift` | THE EXTENSION POINT: `CapabilityPack` protocol (id/name/symbol/permissions/destinations) + `CapabilityRegistry` — future health/photos/location packs register without touching any screen. Template pack proves wiring; zero packs enabled by default. |
| `ios/JarvisApp/JarvisApp.swift` | Root tabs now Sessions / Calls / More. AuthStore, ServerConfig, CCClient, CallManager, WebRTCClient reused unchanged (PKCE cookie-less login kept — verified working). |

### Server side (this box, behind existing Caddy)
| Change | File |
|---|---|
| `POST /feedback` + `GET /feedback/list` on push bridge: HMAC/Bearer dual-auth, durable store (`/opt/jarvis-ios-bridge/feedback.json`), background notification to JARVIS via dashboard turn engine (`project-jarvis-ios` thread), `_shared_secret` Path guard fix | `server/push_bridge/main.py` |
| Offer endpoint: 400 + specific detail on malformed bodies (was 500); DEPLOYED to `/opt/voice-gw/gateway.py` (backup `.bak-fix400-20260921`) and restarted | `server/voice_gateway/gateway.py` |
| WebRTC offer timeout 60s→90s (gateway bootstraps brain inside the offer POST; 20–66s spikes observed) | `ios/JarvisApp/WebRTCClient.swift` |

### Test/contract infra
- `scripts/check_bridge_contract.py`: pinned `POST /feedback` (FeedbackAck: req `ok`, opt `id`/`notified`).

---

## 2. Self-test evidence (REAL outputs, secrets redacted)

### 2.1 Auth (unchanged, re-verified live by API audit)
- Full chain `authorize → password-login (PKCE in body, cookie-less) → native/token → refresh` = **200 at every step**; bad password 401; 429 throttle after 10/min. (server-api-audit.md §2)

### 2.2 Sessions + transcripts (the app's core data path)
- `GET /api/sessions` → **200**; `GET /api/sessions/{id}` → 200; unknown id → 404; `GET /api/sessions/{id}/messages?limit=2` → 200 with `tool_calls` present in message objects. Stats: 1288 sessions, 71717 messages, by_source: cron 998, cli 188, whatsapp 5, signal 3, acp 2, discord 1. (server-api-audit.md §3)

### 2.3 Feedback loop — END TO END, live
```
POST http://127.0.0.1:9160/feedback  (Bearer <minted dashboard token>)
→ HTTP 200 {"ok":true,"id":"56e82f8e","notified":true}

GET /feedback/list → HTTP 200, total 1, latest: "test - live bridge feedback selftest"

JARVIS received it (real reply in /root/.hermes/voice_conversations/project-jarvis-ios.jsonl):
  user: "[iOS app feedback — session livecheck] Category: test / live bridge feedback selftest"
  assistant: "Livecheck ping acknowledged, sir — the bridge loopback is responding as expected."
```
Offline suite (TestClient, isolated state dir): unauth → 401-shape, authed POST → 200, list → 200, empty body → 400.
Bridge contract suite (incl. live throwaway uvicorn): **"bridge contract: ALL GREEN"** (9 routes, 10 live decodes).

### 2.4 Voice gateway (after diagnosis + fixes)
```
Malformed offer (garbage bytes)      → 400 {"detail":"offer body is not valid JSON"}
Malformed offer (missing sdp)        → 400 {"detail":"offer body must be {\"sdp\": <offer SDP>, ...}"}
Valid SDP offer (Bearer, local)      → 200 {"type":"answer","sdp":"v=0 ...","pc_id":true}
Diagnostic aiortc client (worker)    → offer→answer→ICE 'completed'→ 460 RTP frames received, clean close
```

### 2.5 ASC / CI
```
ASC key auth: OK · app record: 6813590605 com.enriquecodes.jarvis "EA's J.A.R.V.I.S"
CI builds: 34 fail (Swift let-mutation) → fixed · 35 fail (missing try) → fixed
           · 36 fail (existential Identifiable) → fixed · **37 SUCCESS**
ASC:        build 37 | VALID | uploaded 2026-09-21T06:44:48Z  (build 33 predecessor)
```

---

## 3. Calling failures — root causes (full report: `voice-failure-diagnosis.md`)

1. **"Ring this phone" VoIP push → APNs 403 InvalidProviderToken.** Reproduced with freshly minted provider tokens against BOTH `api.push.apple.com` and sandbox: 403 every time, while the SAME key authenticates ASC fine. Verdict: the .p8 (kid 2PMV4SF2LS) is an **ASC-only key without APNs capability**. This is Enrique-side: create an APNs-enabled key at developer.apple.com → Keys, then `cp` it to `/opt/jarvis-ios-bridge/apns.key` and re-run `scripts/probe_apns_delivery.py` (expect 400 BadDeviceToken = healthy). NOTE: `APNS_SANDBOX=0` in apns.env matches TestFlight tokens.
2. **In-app calls (no push) work** — gateway proven healthy E2E server-side; stale installed build (fault: phantom `/api/health` 401s) is superseded by this rebuild.
3. **Offer latency spikes 20–66s** (brain bootstrap inside request): client timeout raised to 90s; deeper gateway-side async fix proposed in diagnosis §5.3 (TODO).
4. **Malformed offers 500ed** — now 400 with detail (fixed, deployed, verified).

## 4. Verified-working matrix
| Feature | State |
|---|---|
| Login (PKCE cookie-less) + token refresh | ✅ live-verified |
| Sessions list grouped by project | ✅ endpoint live-verified; UI compiled in build 37 |
| Transcript w/ collapsed tool events | ✅ endpoint live-verified (tool_calls in payload); UI in build 37 |
| Feedback → JARVIS | ✅ **end-to-end live-verified incl. JARVIS reply** |
| In-app WebRTC call (direct, no push) | ✅ server-side E2E (aiortc media); UI in build 37 |
| "Call me back" instant/scheduled | ✅ bridge endpoints live (contract-green); UI in build 37; **push ring blocked on APNs key** |
| Capability-pack extension point | ✅ compiles (build 37); template pack registered, disabled |
| TestFlight | ✅ build 37 VALID (39% processed at last check — completes automatically) |

## 5. Mocked/TODO (honest gaps)
- **APNs key** — needs Enrique's Apple Developer account access (only human-step blocker left). Everything else about calling is done.
- Voice-session bootstrap still runs inside the offer request server-side (mitigated client-side; async refactor = diagnosis §5.3).
- No TURN server (calls fail silently behind symmetric NAT) — diagnosis §5.5, coturn proposed.
- On-device UI flows were verified by **compile + live API contract**, not by a human finger on a phone (no Mac/simulator on this box). Enrique's first manual pass may find UI polish items.
- `SessionsView` groups by `cwd` basename — cross-project sessions without cwd group under source; acceptable v1 behavior.
- Transcript pages at 500 messages (dashboard hard cap); older history needs offset paging UI (TODO).

## 6. How to release the next build
```
cd /root/projects/jarvis-ios
# ... changes ...
git tag ios-v2.0.0-build.N && git push origin ios-v2.0.0-build.N
# CI (ios-release.yml) → xcodegen → match → archive (build-number guards) → TestFlight
```
Test reports: this file, `server-api-audit.md`, `voice-failure-diagnosis.md` in `/root/projects/jarvis-ios-redesign/`.
