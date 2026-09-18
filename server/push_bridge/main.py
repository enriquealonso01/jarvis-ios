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
import json, os, time, uuid, hmac, hashlib, threading
from pathlib import Path
from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel

STATE_DIR = Path(os.environ.get("BRIDGE_STATE_DIR", "/opt/jarvis-ios-bridge"))
ENV_PATH = STATE_DIR / "apns.env"
SCHEDULE_PATH = STATE_DIR / "scheduled_calls.json"


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
        "apns-topic": cfg.get("APNS_BUNDLE_ID", "com.enriquecodes.jarvis.voip"),
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
        return json.loads(SCHEDULE_PATH.read_text() or "[]")
    return []


def _save_schedule(items: list) -> None:
    SCHEDULE_PATH.parent.mkdir(parents=True, exist_ok=True)
    SCHEDULE_PATH.write_text(json.dumps(items, indent=1))


def _scheduler_loop() -> None:
    from datetime import datetime, timezone
    while True:
        now = datetime.now(timezone.utc)
        items = _load_schedule()
        remaining = []
        for item in items:
            due = datetime.fromisoformat(item["at_iso"])
            if due.tzinfo is None:
                due = due.replace(tzinfo=timezone.utc)
            if due <= now:
                _send_voip(item.get("device_token", ""), {"reason": item["reason"], "call_id": item["call_id"], "scheduled_by": item.get("scheduled_by")})
            else:
                remaining.append(item)
        if len(remaining) != len(items):
            _save_schedule(remaining)
        time.sleep(20)


class RegisterReq(BaseModel):
    device_token: str
    bundle_id: str | None = None


class CancelReq(BaseModel):
    call_id: str | None = None  # None/empty cancels all


@app.post("/register")
async def register(request: Request, x_bridge_sig: str = Header(default="")):
    """App calls this on launch with its APNs token; persisted to apns.env
    (DEVICE_TOKEN=...) and auto-injected into every /call + /schedule payload."""
    raw = await request.body()
    _auth(x_bridge_sig, raw)
    req = RegisterReq(**json.loads(raw))
    if not req.device_token or len(req.device_token) < 20:
        raise HTTPException(422, "device_token missing or malformed")
    _save_env_key("DEVICE_TOKEN", req.device_token)
    return {"registered": True, "token_len": len(req.device_token)}


@app.get("/schedule/list")
async def schedule_list(request: Request, x_bridge_sig: str = Header(default="")):
    """List pending scheduled calls. GETs authenticate via HMAC over an empty
    body: sig = HMAC-SHA256(secret, b'')."""
    _auth(x_bridge_sig, b"")
    return {"scheduled": _load_schedule()}


@app.post("/schedule/cancel")
async def schedule_cancel(request: Request, x_bridge_sig: str = Header(default="")):
    """Cancel one scheduled call by call_id, or all if call_id omitted."""
    raw = await request.body()
    _auth(x_bridge_sig, raw)
    req = CancelReq(**json.loads(raw or b"{}"))
    items = _load_schedule()
    kept = [i for i in items if req.call_id and i["call_id"] != req.call_id]
    cancelled = len(items) - len(kept)
    if cancelled:
        _save_schedule(kept)
    return {"cancelled": cancelled}




@app.post("/call")
async def call(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth(x_bridge_sig, raw)
    req = CallReq(**json.loads(raw or b"{}"))
    call_id = str(uuid.uuid4())[:8]
    device_token = _load_env().get("DEVICE_TOKEN", "")
    ok = _send_voip(device_token, {"reason": req.reason, "call_id": call_id, "scheduled_by": req.scheduled_by})
    return {"call_id": call_id, "pushed": ok}


@app.post("/schedule")
async def schedule(request: Request, x_bridge_sig: str = Header(default="")):
    raw = await request.body()
    _auth(x_bridge_sig, raw)
    req = ScheduleReq(**json.loads(raw or b"{}"))
    item = {"call_id": str(uuid.uuid4())[:8], "at_iso": req.at_iso, "reason": req.reason,
            "scheduled_by": req.scheduled_by, "device_token": _load_env().get("DEVICE_TOKEN", "")}
    items = _load_schedule() + [item]
    _save_schedule(items)
    return {"call_id": item["call_id"], "scheduled": True, "at": req.at_iso}


if not os.environ.get("BRIDGE_NO_SCHEDULER"):
    threading.Thread(target=_scheduler_loop, daemon=True).start()
