"""
JARVIS iOS push bridge — places calls to Enrique's iPhone via APNs VoIP pushes.

Endpoints (LAN-only via systemd socket binding + HMAC auth header):
  POST /call        {reason, scheduled_by?}  -> fires VoIP push now; returns call_id
  POST /schedule    {at_iso, reason}         -> registers a future call (in-proc + json persistence)
  GET  /health                               -> ok

The VoIP push payload carries {reason, gateway_ws, call_id}; the app wakes,
shows CallKit UI, and connects its WebRTC view to the voice gateway using
the same flow as the Control Center orb.

APNs auth: .p8 key + key id + team id are read from the gateway secret scope
at runtime (file /opt/jarvis-ios-bridge/apns.env, root-only). NEVER in git.
"""
from __future__ import annotations
import base64, json, os, time, uuid, hmac, hashlib, threading
from pathlib import Path
from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

STATE_DIR = Path(os.environ.get("BRIDGE_STATE_DIR", "/opt/jarvis-ios-bridge"))
ENV_PATH = STATE_DIR / "apns.env"
SCHEDULE_PATH = STATE_DIR / "scheduled_calls.json"
SECRETS_PATH = STATE_DIR / "secrets.json"          # values live here, root-only, never served back
DASH_CONFIG_PATH = Path(os.environ.get("BRIDGE_DASH_CONFIG", "/root/.hermes/config.yaml"))


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
    return f.read_text().strip() if f.exists() else ""


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


def _send_voip(device_token: str, payload: dict) -> bool:
    """Send a VoIP push via APNs HTTP/2. Uses apswift-compatible raw HTTP2 via
    httpx + h2 if available; falls back to `apns2`-style JWT auth."""
    cfg = _load_env()
    key_id, team_id = cfg.get("APNS_KEY_ID"), cfg.get("APNS_TEAM_ID")
    p8 = Path(cfg.get("APNS_P8_PATH", ""))
    if not (key_id and team_id and p8.exists()):
        # Not yet configured: log-and-ack so the loop agent can still develop.
        print(f"[bridge] APNs not configured yet; would push {payload}")
        return False
    import jwt  # pyjwt
    from httpx import Client
    token = jwt.encode({"iss": team_id, "iat": int(time.time())}, p8.read_text(), algorithm="ES256", headers={"kid": key_id})
    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": cfg.get("APNS_BUNDLE_ID", "com.enriquecodes.jarvis"),
        "apns-push-type": "voip",
        "apns-priority": "10",
    }
    url = f"https://api.sandbox.push.apple.com/3/device/{device_token}" if cfg.get("APNS_SANDBOX", "1") == "1" else f"https://api.push.apple.com/3/device/{device_token}"
    with Client(http2=True, timeout=10) as c:
        r = c.post(url, headers=headers, json={"aps": {}, **payload})
        return r.status_code == 200


class CallReq(BaseModel):
    reason: str = "JARVIS call"
    scheduled_by: str | None = None


class ScheduleReq(CallReq):
    at_iso: str


@app.get("/health")
def health():
    cfg = _load_env()
    return {"ok": True, "apns_configured": bool(cfg.get("APNS_KEY_ID")), "scheduled": len(_load_schedule())}


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
            # Malformed entry (bad/missing at_iso etc.) — never fixable, drop it.
            print(f"[bridge] scheduler: dropping malformed entry {item.get('call_id', '?')}: {e}")
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
    if not req.device_token or len(req.device_token) < 20:
        raise HTTPException(422, "device_token missing or malformed")
    _save_env_key("DEVICE_TOKEN", req.device_token)
    return {"registered": True, "token_len": len(req.device_token)}


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
    return {"scheduled": public}


@app.post("/schedule/cancel")
async def schedule_cancel(request: Request, x_bridge_sig: str = Header(default="")):
    """Cancel one scheduled call by call_id, or all if call_id omitted."""
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # agents: HMAC sig; app: dashboard Bearer
    req = CancelReq(**json.loads(raw or b"{}"))
    items = _load_schedule()
    if req.call_id:
        kept = [i for i in items if i["call_id"] != req.call_id]
    else:
        # Documented contract (CancelReq: "None/empty cancels all"): an empty
        # body / empty call_id clears the whole schedule. The old filter kept
        # every item when call_id was None — cancel-all silently did nothing.
        kept = []
    cancelled = len(items) - len(kept)
    if cancelled:
        _save_schedule(kept)
    return {"cancelled": cancelled}




@app.post("/call")
async def call(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # agents: HMAC sig; app: dashboard Bearer
    req = CallReq(**json.loads(raw or b"{}"))
    call_id = str(uuid.uuid4())[:8]
    device_token = _load_env().get("DEVICE_TOKEN", "")
    ok = _send_voip(device_token, {"reason": req.reason, "call_id": call_id, "scheduled_by": req.scheduled_by, "gateway_ws": "/voice-gw"})
    return {"call_id": call_id, "pushed": ok}


@app.post("/schedule")
async def schedule(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth_dual(request, x_bridge_sig, raw)   # agents: HMAC sig; app: dashboard Bearer
    req = ScheduleReq(**json.loads(raw or b"{}"))
    item = {"call_id": str(uuid.uuid4())[:8], "at_iso": req.at_iso, "reason": req.reason,
            "scheduled_by": req.scheduled_by, "device_token": _load_env().get("DEVICE_TOKEN", "")}
    items = _load_schedule() + [item]
    _save_schedule(items)
    return {"call_id": item["call_id"], "scheduled": True, "at": req.at_iso}


if not os.environ.get("BRIDGE_NO_SCHEDULER"):
    threading.Thread(target=_scheduler_loop, daemon=True).start()
