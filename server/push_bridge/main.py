"""
JARVIS iOS push bridge — places calls to Enrique's iPhone via APNs VoIP pushes.

Endpoints (LAN-only via systemd socket binding + HMAC auth header):
  POST /call        {reason, scheduled_by?}  -> fires VoIP push now; returns call_id
  POST /schedule    {at_iso, reason}         -> registers a future call (in-proc + json persistence)
  GET  /health                               -> ok, incl. dropped_calls (1k scheduler drop log)

The VoIP push payload carries {reason, gateway_ws, call_id}; the app wakes,
shows CallKit UI, and connects its WebRTC view to the voice gateway using
the same flow as the Control Center orb.

APNs auth: .p8 key + key id + team id are read from the gateway secret scope
at runtime (file /opt/jarvis-ios-bridge/apns.env, root-only). NEVER in git.
"""
from __future__ import annotations
import asyncio, base64, json, os, subprocess, time, uuid, hmac, hashlib, threading
from datetime import datetime, timezone
from pathlib import Path
from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

STATE_DIR = Path(os.environ.get("BRIDGE_STATE_DIR", "/opt/jarvis-ios-bridge"))
ENV_PATH = STATE_DIR / "apns.env"
SCHEDULE_PATH = STATE_DIR / "scheduled_calls.json"
DROPS_PATH = STATE_DIR / "dropped_calls.json"      # scheduler drop log (1k): calls the bridge gave up on
SECRETS_PATH = STATE_DIR / "secrets.json"          # values live here, root-only, never served back
COUNTERS_PATH = STATE_DIR / "push_counters.json"   # push success/failure counters (dev-observability)
DASH_CONFIG_PATH = Path(os.environ.get("BRIDGE_DASH_CONFIG", "/root/.hermes/config.yaml"))
# Profile router (JARVIS specialists / Bots): the box's `jarvis-route` CLI, which answers
# {"profile", "confidence", "reason", "title"} for a message. The app asks it on the first
# message of a new default-profile chat (docs/agents/bots.md, "Opened in <Bot>").
ROUTE_BIN = os.environ.get("BRIDGE_ROUTE_BIN", "/usr/local/bin/jarvis-route")
ROUTE_TIMEOUT_S = float(os.environ.get("BRIDGE_ROUTE_TIMEOUT_S", "12"))


def _save_env_key(key: str, value: str) -> None:
    """Persist KEY=value into apns.env (EnvironmentFile + runtime config)."""
    ENV_PATH.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            if line.split("=", 1)[0].strip() != key:
                lines.append(line)
    lines.append(f"{key}={value}")
    ENV_PATH.write_text("\n".join(lines) + "\n")
    os.chmod(ENV_PATH, 0o600)
def _shared_secret() -> str:
    env = os.environ.get("BRIDGE_SHARED_SECRET", "")
    if env:
        return env
    f = Path(os.environ.get("BRIDGE_SHARED_SECRET_FILE", ""))
    # Guard: BRIDGE_SHARED_SECRET_FILE pointing at a directory (or cwd when
    # the var is unset-and-empty → Path('')) must not crash import.
    if f and f != Path(".") and f.is_file():
        return f.read_text().strip()
    return ""


SECRET = _shared_secret()

app = FastAPI(title="jarvis-ios-push-bridge", version="0.1.0")


def _load_env() -> dict:
    cfg = {}
    if ENV_PATH.exists():
        for line in ENV_PATH.read_text().splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


def _auth(x_bridge_sig: str, body: bytes) -> None:
    if not SECRET:
        raise HTTPException(503, "bridge not configured (no shared secret)")
    expected = hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, x_bridge_sig or ""):
        raise HTTPException(401, "bad signature")


def _bump_push_counters(ok: bool) -> None:
    """Persist push success/failure counters to push_counters.json.

    Dev-observability (dev-success-counter contract, PROGRESS 2026-09-19):
    /health exposes the totals so the device-watch's MISSION-COMPLETE message
    (and any later audit) can verify that a real delivery actually happened
    after the key flip — `last_push_error` alone cannot ("" means only
    'nothing failed YET', never 'a push succeeded').
    Best-effort: a counter write failure must never affect the push result.
    """
    try:
        data = {}
        if COUNTERS_PATH.exists():
            try:
                data = json.loads(COUNTERS_PATH.read_text() or "{}")
            except Exception:
                data = {}
        key = "push_ok" if ok else "push_fail"
        data[key] = int(data.get(key, 0)) + 1
        data["last_at"] = int(time.time())
        COUNTERS_PATH.write_text(json.dumps(data))
        os.chmod(COUNTERS_PATH, 0o600)
    except Exception as e:
        print(f"[bridge] push-counter write failed (non-fatal): {e}")


def _send_voip(device_token: str, payload: dict) -> bool:
    """Send a VoIP push via APNs over HTTP/2 (httpx + h2) with provider-token
    JWT auth (pyjwt ES256, kid header). Config/token read per call.

    Failure must be LOUD: a silent False here is indistinguishable from "no
    phone registered" for every caller (scheduler, /call, call_enrique.py).
    On any non-200, log status + Apple's `reason` string. Found the first
    InvalidProviderToken (p8 without APNs capability) exactly this way —
    see scripts/probe_apns_delivery.py + PROGRESS 2026-09-18 22:20.
    TRANSPORT failures (h2 handshake, timeout, connection reset) are caught
    and recorded the same way (LAST_PUSH_ERROR=`transport <Error>`, loud log)
    — never raised into POST /call, which has no handler of its own
    (transport-guard contract, PROGRESS 2026-09-18 23:40).
    """
    cfg = _load_env()
    key_id, team_id = cfg.get("APNS_KEY_ID"), cfg.get("APNS_TEAM_ID")
    p8 = Path(cfg.get("APNS_P8_PATH", ""))
    if not (key_id and team_id and p8.exists()):
        _save_env_key("LAST_PUSH_ERROR", "unconfigured")
        # Not yet configured: log-and-ack so the loop agent can still develop.
        # NOT counted in push counters — nothing reached Apple (attempt-only
        # semantics: push_ok/push_fail count real Apple round-trips).
        print(f"[bridge] APNs not configured yet; would push {payload}")
        return False
    if not device_token:
        # No registered device (or snapshot empty): nothing to push to.
        # Distinct log line so "no device" never masquerades as "APNs broken".
        # NOT counted (see above — no Apple round-trip happened).
        print("[bridge] push skipped: no DEVICE_TOKEN registered yet")
        return False
    import jwt  # pyjwt
    from httpx import Client
    token = jwt.encode({"iss": team_id, "iat": int(time.time())}, p8.read_text(), algorithm="ES256", headers={"kid": key_id})
    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": cfg.get("APNS_BUNDLE_ID", "com.enriquecodes.jarvis") + ".voip",
        "apns-push-type": "voip",
        "apns-priority": "10",
    }
    url = f"https://api.sandbox.push.apple.com/3/device/{device_token}" if cfg.get("APNS_SANDBOX", "1") == "1" else f"https://api.push.apple.com/3/device/{device_token}"
    # Transport guard: the POST itself is wrapped — an h2 handshake failure /
    # timeout / connection reset must surface as a LOUD, recorded False, never
    # as an unhandled exception escaping into POST /call. (httpx+h2 to Apple
    # re-proven live 2026-09-18 23:40: proto=HTTP/2 on BOTH hosts — the old
    # "egress mangles python h2" note was a urllib-era artifact; see the
    # probe's BRIDGE-STACK leg, which exercises this exact stack.)
    try:
        with Client(http2=True, timeout=10) as c:
            r = c.post(url, headers=headers, json={"aps": {}, **payload})
    except Exception as e:
        print(f"[bridge] APNs push TRANSPORT ERROR: {type(e).__name__}: {e} "
              f"(host={'sandbox' if cfg.get('APNS_SANDBOX') == '1' else 'production'})")
        _save_env_key("LAST_PUSH_ERROR", f"transport {type(e).__name__} at {int(time.time())}")
        _bump_push_counters(False)
        return False
    if r.status_code == 200:
        _save_env_key("LAST_PUSH_ERROR", "")
        _bump_push_counters(True)
        return True
    try:
        reason = r.json().get("reason", "")
    except Exception:
        reason = (r.text or "")[:120]
    print(f"[bridge] APNs push REJECTED: HTTP {r.status_code} {reason} "
          f"(topic={headers['apns-topic']}, host={'sandbox' if cfg.get('APNS_SANDBOX') == '1' else 'production'})")
    _save_env_key("LAST_PUSH_ERROR", f"{r.status_code} {reason} at {int(time.time())}")
    _bump_push_counters(False)
    return False


class CallReq(BaseModel):
    reason: str = "JARVIS call"
    scheduled_by: str | None = None


# Reason/text-size guards (1g, 2026-09-19): `reason` rides INSIDE the APNs
# push payload ({"aps": {}, **payload} in _send_voip), and Apple rejects any
# notification over 4096 bytes with HTTP 413. POST /schedule persists the
# reason for the scheduler to fire later, so an oversized reason meant:
# persisted fine -> fire time -> APNs 413 -> retry 10x -> silently dropped —
# the exact silent-never class the at_iso guard (1f-bis) closed, via the
# payload-SIZE seam. Both write surfaces (/call, /schedule) therefore validate
# BEFORE anything fires or persists. 3500 bytes leaves >500 bytes of envelope
# headroom under the 4096 hard limit.
MAX_REASON_BYTES = 3500
MAX_SCHEDULED_BY_CHARS = 200


def _validate_push_text(reason: str, scheduled_by: str | None) -> str:
    """Return the cleaned reason; 400 with a pinned detail on violation.
    Pinned offline + live by scripts/check_bridge_contract.py
    (guard probes /call#empty /call#huge /schedule#huge)."""
    r = (reason or "").strip()
    if not r:
        raise HTTPException(status_code=400,
                            detail="reason must not be empty — it is what the call screen shows")
    rbytes = len(r.encode("utf-8"))
    if rbytes > MAX_REASON_BYTES:
        raise HTTPException(status_code=400,
                            detail=f"reason too long ({rbytes} bytes UTF-8 > {MAX_REASON_BYTES} limit) — APNs rejects any notification payload over 4096 bytes, so this would burn 10 scheduler retries then silently drop the call")
    if scheduled_by and len(scheduled_by) > MAX_SCHEDULED_BY_CHARS:
        raise HTTPException(status_code=400,
                            detail=f"scheduled_by too long ({len(scheduled_by)} > {MAX_SCHEDULED_BY_CHARS} chars) — it also rides the APNs payload")
    return r


class ScheduleReq(CallReq):
    at_iso: str


@app.get("/health")
def health():
    cfg = _load_env()
    # device_registered (backlog #4 close-out): lets the CC/app/watch crons see
    # WHEN the phone has completed its /register handshake without exposing any
    # token material (boolean presence only — never the token or its length).
    # push_ok/push_fail (dev-success-counter contract): real Apple round-trip
    # totals — prove (or disprove) that a delivery actually happened.
    # last_push_error == "" only means "nothing failed recently"; only
    # push_ok >= 1 is evidence of a delivered push.
    counters = {}
    if COUNTERS_PATH.exists():
        try:
            counters = json.loads(COUNTERS_PATH.read_text() or "{}")
        except Exception:
            counters = {}
    return {"ok": True, "apns_configured": bool(cfg.get("APNS_KEY_ID")),
            "device_registered": bool(cfg.get("DEVICE_TOKEN")),
            "last_push_error": cfg.get("LAST_PUSH_ERROR", ""),
            "push_ok": int(counters.get("push_ok", 0)),
            "push_fail": int(counters.get("push_fail", 0)),
            "scheduled": len(_load_schedule()),
            # Scheduler drop log (1k): how many scheduled calls the bridge has
            # GIVEN UP on are still in the log (ring buffer, capped). 0 means
            # nothing dropped SINCE the log was last cleared — never proof a
            # call fired (push_ok >= 1 remains the only delivery evidence).
            "dropped_calls": len(_load_drops())}


def _load_schedule() -> list:
    if SCHEDULE_PATH.exists():
        try:
            return json.loads(SCHEDULE_PATH.read_text() or "[]")
        except Exception as e:
            # Corrupt state file must not kill the scheduler loop — back it up
            # once and start fresh (PROGRESS 2026-09-18 09:50).
            try:
                SCHEDULE_PATH.rename(SCHEDULE_PATH.with_suffix(".corrupt"))
                print(f"[bridge] schedule file corrupt (backed up as .corrupt): {e}")
            except Exception:
                pass
            return []
    return []


def _save_schedule(items: list) -> None:
    SCHEDULE_PATH.parent.mkdir(parents=True, exist_ok=True)
    SCHEDULE_PATH.write_text(json.dumps(items, indent=1))


# ------------------------------------------------- scheduler drop log (1k) ---
# A scheduled call the bridge gives up on used to vanish with ONLY a container
# log line: after 10 failed push attempts (dead token, broken key, transport
# outage) the entry was removed and /health kept reporting scheduled:N with no
# trace, so "call me at 10am" could silently never happen and nobody could
# tell. Every drop is now appended to dropped_calls.json (capped ring buffer)
# and surfaced by GET /health as dropped_calls + GET /schedule/list as
# dropped: [...]. Best-effort writes: observability must never kill the tick.
DROPS_MAX = 50


def _record_drop(item: dict, why: str) -> None:
    """Append one drop entry (best-effort; never raises into the tick)."""
    try:
        try:
            drops = json.loads(DROPS_PATH.read_text() or "[]")
        except Exception:
            drops = []
        drops.append({
            "call_id": str(item.get("call_id", "?")),
            "reason": str(item.get("reason", "")),
            "at_iso": str(item.get("at_iso", "")),
            "scheduled_by": item.get("scheduled_by"),
            "dropped_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "why": why,
        })
        DROPS_PATH.write_text(json.dumps(drops[-DROPS_MAX:], indent=1))
    except Exception as e:
        print(f"[bridge] drop-log write failed (non-fatal): {e}")


def _load_drops() -> list:
    try:
        drops = json.loads(DROPS_PATH.read_text() or "[]")
        return drops if isinstance(drops, list) else []
    except Exception:
        return []


def _run_scheduler_tick() -> None:
    """One scheduler pass. Robustness contract (PROGRESS 2026-09-18 09:50):
    a malformed entry is dropped, a failed push retries up to 10 ticks then
    drops, and no per-item error may escape to kill the loop."""
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    items = _load_schedule()
    remaining = []
    for item in items:
        try:
            due = datetime.fromisoformat(item["at_iso"])
            if due.tzinfo is None:
                due = due.replace(tzinfo=timezone.utc)
            if due > now:
                remaining.append(item)
                continue
            payload = {"reason": item["reason"], "call_id": item["call_id"],
                       "scheduled_by": item.get("scheduled_by"), "gateway_ws": "/voice-gw"}
        except Exception as e:
            # Malformed entry (bad/missing at_iso etc.) — never fixable, drop
            # it — and LOG it (1k): a silent drop is indistinguishable from
            # "the call happened" everywhere else.
            print(f"[bridge] scheduler: dropping malformed entry {item.get('call_id', '?')}: {e}")
            _record_drop(item, f"malformed entry: {e}")
            continue
        try:
            # Fire-time token: ALWAYS prefer the bridge's CURRENT registered
            # DEVICE_TOKEN; the /schedule snapshot can be EMPTY (device not
            # yet registered when the call was scheduled — fresh install)
            # or STALE (app reinstall mints a new APNs token). Falling back
            # to the snapshot only when nothing is registered keeps old
            # state working but never pushes at a dead token.
            live_token = _load_env().get("DEVICE_TOKEN", "")
            ok = _send_voip(live_token or item.get("device_token", ""), payload)
        except Exception as e:
            print(f"[bridge] scheduler: push error for {item.get('call_id', '?')}: {e}")
            ok = False
        if ok:
            print(f"[bridge] scheduler: fired {item.get('call_id')} ({str(item.get('reason', ''))[:60]})")
        else:
            # Unconfigured APNs or transient push failure: retry, capped.
            item["failures"] = item.get("failures", 0) + 1
            if item["failures"] < 10:
                remaining.append(item)
                print(f"[bridge] scheduler: {item.get('call_id')} push failed (attempt {item['failures']}/10, retrying)")
            else:
                # Gave up for good (1k): record it in the drop log — removal
                # from the schedule must never be silent again.
                _record_drop(item, f"push failed {item['failures']} times — gave up")
                print(f"[bridge] scheduler: {item.get('call_id')} dropped after 10 failed push attempts")
    if len(remaining) != len(items):
        _save_schedule(remaining)


def _scheduler_loop() -> None:
    while True:
        try:
            _run_scheduler_tick()
        except Exception as e:
            # Never let one bad tick kill the scheduler thread — a dead loop
            # means every future scheduled call silently never fires.
            print(f"[bridge] scheduler tick error (loop survives): {e}")
        time.sleep(20)


class RegisterReq(BaseModel):
    device_token: str
    bundle_id: str | None = None


class CancelReq(BaseModel):
    call_id: str | None = None  # None/empty cancels all


# ---------------------------------------------------------------- secrets ---
# Named-secret store (backlog #3). Values persist server-side only
# (secrets.json, 0600) and are NEVER returned by any endpoint — only names,
# masked previews (first 2 chars + length) and timestamps. Auth is dual:
#   - agents: x-bridge-sig HMAC (same as every other endpoint)
#   - iOS app: `Authorization: Bearer <access>` where the token is the same
#     stateless HMAC access token the dashboard `basic` provider mints
#     (identical verify ladder to the voice gateway's bearer gate — sig +
#     kind=access + exp — verified locally, no dashboard round-trip).

def _dash_secret_bytes() -> bytes:
    import yaml
    try:
        cfg = yaml.safe_load(open(DASH_CONFIG_PATH))
    except Exception:
        return b""
    raw = (cfg.get("dashboard") or {}).get("basic_auth", {}).get("secret", "")
    for decoder in (base64.b64decode, bytes.fromhex):
        try:
            cand = decoder(raw)
            if len(cand) >= 16:
                return cand
        except Exception:
            continue
    return raw.encode() if raw else b""


def _bearer_valid(token: str) -> bool:
    secret = _dash_secret_bytes()
    if not secret:
        return False
    try:
        blob = base64.urlsafe_b64decode(token.encode())
        payload, sig = blob[:-32], blob[-32:]
        if not hmac.compare_digest(hmac.new(secret, payload, hashlib.sha256).digest(), sig):
            return False
        data = json.loads(payload)
        return data.get("kind") == "access" and data.get("exp", 0) > int(time.time())
    except Exception:
        return False


def _auth_dual(request: Request, x_bridge_sig: str, body: bytes) -> None:
    """HMAC sig if present, else dashboard Bearer. Never both required."""
    bearer = (request.headers.get("authorization") or "").removeprefix("Bearer ").strip()
    if bearer:
        if _bearer_valid(bearer):
            return
        raise HTTPException(401, "bad bearer token")
    _auth(x_bridge_sig, body)


def _load_secrets() -> dict:
    if SECRETS_PATH.exists():
        try:
            return json.loads(SECRETS_PATH.read_text() or "{}")
        except Exception:
            return {}
    return {}


def _save_secrets(data: dict) -> None:
    SECRETS_PATH.parent.mkdir(parents=True, exist_ok=True)
    SECRETS_PATH.write_text(json.dumps(data, indent=1))
    os.chmod(SECRETS_PATH, 0o600)


def _secret_meta(data: dict) -> list:
    out = []
    for name, entry in sorted(data.items()):
        val = str(entry.get("value", ""))
        out.append({
            "name": name,
            "masked": (val[:2] + "…" if len(val) > 6 else "••••••"),
            "length": len(val),
            "updated_at": entry.get("updated_at", ""),
            "updated_by": entry.get("updated_by", ""),
        })
    return out


class SecretReq(BaseModel):
    name: str
    value: str = "x"
    updated_by: str | None = "ios-app"


NAMING_CACHE_PATH = Path("/root/.hermes/cache/session_naming.json")


def _load_naming_cache() -> dict:
    """Session titles + project tags written by server/session_naming.py."""
    try:
        return json.loads(NAMING_CACHE_PATH.read_text() or "{}")
    except Exception:
        return {}


@app.get("/projects/meta")
async def projects_meta(request: Request, x_bridge_sig: str = Header(default="")):
    """Per-session project tags + human titles for the iOS Sessions view.

    Auth: same dual scheme as the other GETs (dashboard Bearer or HMAC sig).
    Served from the naming agent's cache (root-only file) — never exposes
    transcript content.
    """
    _auth_dual(request, x_bridge_sig, b"")
    cache = _load_naming_cache()
    return {
        "projects": cache.get("projects") or {},
        "titles": {k.split(":", 1)[0]: v for k, v in (cache.get("titles") or {}).items()},
        "updated_at": cache.get("projects_updated_at"),
    }


@app.get("/secrets")
async def secrets_list(request: Request, x_bridge_sig: str = Header(default="")):
    """List stored secret NAMES with masked previews. Values never leave the box."""
    _auth_dual(request, x_bridge_sig, b"")
    return {"secrets": _secret_meta(_load_secrets())}


@app.post("/secrets/set")
async def secrets_set(request: Request, x_bridge_sig: str = Header(default="")):
    """Create/update a named secret. Stored 0600 server-side; never echoed back."""
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)
    req = SecretReq(**json.loads(raw))
    name = req.name.strip()
    if not name or "=" in name or len(name) > 128:
        raise HTTPException(422, "invalid secret name")
    if not req.value:
        raise HTTPException(422, "value required")
    data = _load_secrets()
    existed = name in data
    data[name] = {"value": req.value,
                  "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "updated_by": req.updated_by or "ios-app"}
    _save_secrets(data)
    return {"ok": True, "name": name, "created": not existed, "stored": True}


@app.post("/secrets/delete")
async def secrets_delete(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)
    body = json.loads(raw or b"{}")
    name = str(body.get("name", "")).strip()
    if not name:
        raise HTTPException(422, "name required")
    data = _load_secrets()
    existed = data.pop(name, None) is not None
    if existed:
        _save_secrets(data)
    return {"ok": True, "deleted": existed}


@app.post("/register")
async def register(request: Request, x_bridge_sig: str = Header(default="")):
    """App calls this on launch with its APNs token; persisted to apns.env
    (DEVICE_TOKEN=...) and auto-injected into every /call + /schedule payload."""
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # agents: HMAC sig; app: dashboard Bearer
    req = RegisterReq(**json.loads(raw))
    # Token-format guard (1f-ter, 2026-09-19): DEVICE_TOKEN is the bridge's
    # ONLY push address. Persisting a malformed value doesn't error anywhere —
    # device_registered stays true, every future /call + /schedule fires at the
    # dead token, push_fail climbs, and "ring this phone" is dead until an
    # agent notices. PushKit tokens are lowercase hex (the app converts the
    # raw bytes with String(format: "%02x")) and 32 bytes = 64 chars, so pin
    # format+length BEFORE anything is persisted — same seam class as the
    # /schedule at_iso guard (1f-bis). Pinned offline + live by
    # scripts/check_bridge_contract.py (guard probes /register#short / #nonhex).
    token = (req.device_token or "").strip()
    if len(token) < 64:
        raise HTTPException(status_code=400,
                            detail="device_token too short — PushKit tokens are 64 hex chars (32 bytes); refusing to overwrite a working registration")
    if any(c not in "0123456789abcdef" for c in token):
        raise HTTPException(status_code=400,
                            detail="device_token must be lowercase hex (0-9a-f); refusing to overwrite a working registration")
    _save_env_key("DEVICE_TOKEN", token)
    return {"registered": True, "token_len": len(token)}


@app.get("/schedule/list")
async def schedule_list(request: Request, x_bridge_sig: str = Header(default="")):
    """List pending scheduled calls. GETs authenticate via HMAC over an empty
    body: sig = HMAC-SHA256(secret, b'') — or the app's dashboard Bearer.

    device_token (the snapshotted APNs token) and the internal `failures`
    counter are STRIPPED from the response — the device token is a secret
    that identifies the phone for pushes; only the scheduler fire path needs
    it, never a client. The app's Decodable model has no such field anyway.
    """
    _auth_dual(request, x_bridge_sig, b"")
    public = []
    for item in _load_schedule():
        entry = {k: v for k, v in item.items() if k not in ("device_token", "failures")}
        public.append(entry)
    # 1k: the scheduler drop log rides along — a call the bridge gave up on
    # (10 failed pushes, malformed entry) is visible here instead of only in
    # container logs. Same auth, same response; the pending list is untouched.
    return {"scheduled": public, "dropped": _load_drops()}


@app.post("/schedule/cancel")
async def schedule_cancel(request: Request, x_bridge_sig: str = Header(default="")):
    """Cancel one scheduled call by call_id, or all if call_id omitted.

    Guard (1j, 2026-09-19): cancel-ALL requires an EXPLICIT {"confirm": true}.
    The empty body is a valid-but-dangerous shape — the scheduler has no undo,
    so one buggy agent probe / test body / confused voice call wiped every
    pending reminder silently and permanently. A WHITESPACE-ONLY call_id (e.g.
    --id " ") no longer masquerades as cancel-all either: truthy → it targets
    a call_id that can never exist, so it 404s loudly instead of no-op wiping
    the whole schedule (cancelled:0 with everything still gone is the lie that
    shape told before). A malformed NON-STRING call_id 400s BEFORE model
    construction: pydantic v2 does not coerce — it raises a raw
    ValidationError that uvicorn surfaces as an opaque 500 Internal Server
    Error (the v1-era coercion-to-"" hazard is gone, but an unexplained 500
    is its own silent-failure class for the client).
    Cancel-ONE is confirm-free: it targets exactly one visible id.
    """
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # agents: HMAC sig; app: dashboard Bearer
    body = json.loads(raw or b"{}")
    # call_id must be a string if present — checked BEFORE CancelReq(**body)
    # (see the docstring: pydantic v2 would 500, not coerce).
    if "call_id" in body and body["call_id"] is not None and not isinstance(body["call_id"], str):
        raise HTTPException(status_code=400, detail="call_id must be a string")
    req = CancelReq(**body)
    items = _load_schedule()
    if req.call_id:
        # Strip before matching: a whitespace-padded id matched NOTHING above,
        # but truthy req.call_id also skipped the cancel-all branch — the old
        # code returned cancelled:0 while implying "one id targeted". Now it
        # says plainly that no such call exists (404), never silently wiping.
        cid = req.call_id.strip()
        if not cid:
            raise HTTPException(status_code=404, detail="call_id is empty (whitespace-only) — send {\"confirm\": true} to cancel ALL, or a real call_id from /schedule/list")
        kept = [i for i in items if i["call_id"] != cid]
        cancelled = len(items) - len(kept)
        if cancelled == 0:
            raise HTTPException(status_code=404, detail=f"no scheduled call with call_id {cid!r} — see /schedule/list (nothing was cancelled)")
        if cancelled:
            _save_schedule(kept)
        return {"cancelled": cancelled}
    else:
        # Cancel-all keeps working (the documented contract) but only when the
        # caller MEANT it: an explicit confirm flag. Anything else 400s with
        # the exact remedy — before the 1j fix, {"call_id": ""} (pydantic
        # coercion of a non-string 0/False lands here too) wiped everything.
        if body.get("confirm") is not True:
            raise HTTPException(status_code=400,
                                detail="cancel-all requires {\"confirm\": true} — it wipes EVERY pending call and cannot be undone; to cancel one call send {\"call_id\": \"<id from /schedule/list>\"}")
        _save_schedule([])
        return {"cancelled": len(items)}




@app.post("/call")
async def call(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # agents: HMAC sig; app: dashboard Bearer
    req = CallReq(**json.loads(raw or b"{}"))
    # Text guards (1g): reason rides the APNs payload — empty or oversized
    # text 400s here instead of burning push attempts at Apple (see
    # _validate_push_text for the full why).
    req.reason = _validate_push_text(req.reason, req.scheduled_by)
    call_id = str(uuid.uuid4())[:8]
    device_token = _load_env().get("DEVICE_TOKEN", "")
    ok = _send_voip(device_token, {"reason": req.reason, "call_id": call_id, "scheduled_by": req.scheduled_by, "gateway_ws": "/voice-gw"})
    return {"call_id": call_id, "pushed": ok}


@app.post("/schedule")
async def schedule(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # agents: HMAC sig; app: dashboard Bearer
    req = ScheduleReq(**json.loads(raw or b"{}"))
    # Validation guards (1f-bis, 2026-09-19): the scheduler fires any persisted
    # entry whose at_iso <= now on its next 20s tick, so an unvalidated body
    # meant a garbage timestamp persisted silently (dropped as malformed at
    # fire time — the call never happens, no error anywhere) and a past
    # timestamp rang Enrique INSTANTLY. Both must fail here, loudly, before
    # anything is persisted. Pinned offline + live by
    # scripts/check_bridge_contract.py (guard probes /schedule#bad / #past).
    try:
        due = datetime.fromisoformat(req.at_iso.strip())
    except ValueError:
        raise HTTPException(status_code=400,
                            detail="at_iso is not a valid ISO-8601 timestamp")
    if due.tzinfo is None:
        due = due.replace(tzinfo=timezone.utc)
    if due <= datetime.now(timezone.utc):
        raise HTTPException(status_code=400,
                            detail="at_iso is in the past (UTC) — refusing to schedule an instant call")
    # Text guards (1g, same seam as /call): an oversized reason persists fine
    # but can NEVER be delivered — at fire time APNs rejects the >4KB payload,
    # the scheduler burns its 10 retries, and the call silently drops. Guarded
    # BEFORE anything is persisted.
    req.reason = _validate_push_text(req.reason, req.scheduled_by)
    item = {"call_id": str(uuid.uuid4())[:8], "at_iso": req.at_iso, "reason": req.reason,
            "scheduled_by": req.scheduled_by, "device_token": _load_env().get("DEVICE_TOKEN", "")}
    items = _load_schedule() + [item]
    _save_schedule(items)
    return {"call_id": item["call_id"], "scheduled": True, "at": req.at_iso}


if not os.environ.get("BRIDGE_NO_SCHEDULER"):
    threading.Thread(target=_scheduler_loop, daemon=True).start()


# ------------------------------------------------------------- feedback -----
# In-app "something is not going correctly" reports from the redesigned iOS
# app. Stored durably (feedback.json), then JARVIS is notified in the
# background via the dashboard's project-task turn engine so the report
# actually LANDS with him (requirement #3), not just with a file.

FEEDBACK_PATH = STATE_DIR / "feedback.json"


def _load_feedback() -> list:
    try:
        return json.loads(FEEDBACK_PATH.read_text())
    except Exception:  # noqa: BLE001
        return []


def _save_feedback(items: list) -> None:
    tmp = FEEDBACK_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(items[-500:], indent=1))
    tmp.replace(FEEDBACK_PATH)


def _notify_jarvis_feedback(report: dict) -> None:
    """Fire-and-forget: hand the report to JARVIS via the dashboard turn
    engine (same path the CC project-task button uses). Never raises."""
    import httpx
    try:
        headers = {"Cookie": f"hermes_session_at={_mint_dash_token()}"}
        text = (f'[iOS app feedback — session {report.get("session_id", "?")}]\n'
                f'Category: {report.get("category", "unspecified")}\n'
                f'{report.get("text") or "(no details written)"}')
        httpx.post("http://127.0.0.1:9119/api/control/project/task",
                   json={"project": "jarvis-ios", "text": text},
                   headers=headers, timeout=30.0)
    except Exception as exc:  # noqa: BLE001
        print(f"[bridge] feedback notify failed: {exc}", flush=True)


def _mint_dash_token() -> str:
    """Mint the dashboard basic-provider HMAC access token (same scheme the
    voice gateway uses to call the dashboard over loopback)."""
    import yaml
    try:
        cfg = yaml.safe_load(open(DASH_CONFIG_PATH))
    except Exception:  # noqa: BLE001
        return ""
    ba = (cfg.get("dashboard") or {}).get("basic_auth") or {}
    raw = ba.get("secret", "")
    secret = None
    for decoder in (base64.b64decode, bytes.fromhex):
        try:
            cand = decoder(raw)
            if len(cand) >= 16:
                secret = cand
                break
        except Exception:  # noqa: BLE001
            continue
    if secret is None:
        secret = raw.encode()
    payload = {"sub": ba.get("username", "ios-bridge"),
               "kind": "access", "exp": int(time.time()) + 3600}
    blob = json.dumps(payload, separators=(",", ":")).encode()
    sig = hmac.new(secret, blob, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(blob + sig).decode()


@app.post("/feedback")
async def feedback(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # app: dashboard Bearer; agents: HMAC
    body = json.loads(raw or b"{}")
    session_id = str(body.get("session_id") or "")[:120]
    category = str(body.get("category") or "something went wrong")[:80]
    text = str(body.get("text") or "")[:4000]
    message_id = body.get("message_id")
    if not session_id and not text:
        raise HTTPException(status_code=400,
                            detail="feedback needs a session_id and/or text")
    report = {
        "id": str(uuid.uuid4())[:8],
        "ts": time.time(),
        "session_id": session_id,
        "message_id": message_id if isinstance(message_id, int) else None,
        "category": category,
        "text": text,
    }
    items = _load_feedback()
    items.append(report)
    _save_feedback(items)
    threading.Thread(target=_notify_jarvis_feedback, args=(report,), daemon=True).start()
    return {"ok": True, "id": report["id"], "notified": True}


@app.get("/feedback/list")
async def feedback_list(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)
    items = _load_feedback()
    return {"items": items[-100:], "total": len(items)}


# ---------------------------------------------------------------------------
# Bot routing (the JARVIS profiles rollout, 2026-10-22). The app's first message in a
# new default-profile chat comes here; the reply names the specialist profile that should
# own the chat, or "general". Auth: the app's dashboard Bearer or an agent's HMAC sig.
@app.post("/route")
async def route(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # app: dashboard Bearer; agents: HMAC
    body = json.loads(raw or b"{}")
    text = str(body.get("text") or "").strip()[:2000]
    if not text:
        raise HTTPException(status_code=400, detail="route needs text")
    current = str(body.get("profile") or "").strip()[:64]
    args = [ROUTE_BIN] + (["--current", current] if current else []) + [text]
    # The router hedges Z.AI and Fireworks and falls back to keywords; a short per-call cap
    # keeps the whole answer inside the app's wait.
    env = dict(os.environ, HOME=os.environ.get("HOME") or "/root", JARVIS_CLASSIFY_TIMEOUT="5")

    def run() -> subprocess.CompletedProcess:
        return subprocess.run(args, capture_output=True, text=True, timeout=ROUTE_TIMEOUT_S, env=env)

    try:
        proc = await asyncio.to_thread(run)
        line = (proc.stdout or "").strip().splitlines()[-1]
        data = json.loads(line)
    except (subprocess.TimeoutExpired, FileNotFoundError, IndexError, ValueError, OSError) as exc:
        raise HTTPException(status_code=503, detail=f"router unavailable: {type(exc).__name__}")
    profile = str(data.get("profile") or "general")
    try:
        confidence = float(data.get("confidence", 0.0))
    except (TypeError, ValueError):
        confidence = 0.0
    return {"profile": profile, "confidence": confidence,
            "reason": str(data.get("reason") or "")[:120], "title": data.get("title")}
