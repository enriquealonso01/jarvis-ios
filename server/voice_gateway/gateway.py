#!/usr/bin/env python3
"""JARVIS Voice Gateway v2 (port 9150) — "JARVIS Live".

One Pipecat voice pipeline, two surfaces:
  - browser / phone PWA: SmallWebRTC (POST /voice-gw/api/offer from /voice-gw/)
  - Discord voice: frames fed in by discord_adapter.py

Brain: a streaming, tool-calling LLM (brain.py) that can call the Control
Center's fast lookup tools directly and hand real work to the full JARVIS
agent (the dashboard's /api/control/voice/turn engine) in the background.

Auth: every /voice-gw/* route except the health check requires the SAME
dashboard session cookie the Control Center uses (validated against the
dashboard over loopback, cached briefly). The v1 gateway (2026-09-15) was
reachable by anyone on the internet — do not remove this.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac as hmac_mod
import json
import logging
import os
import re
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, Optional

import httpx
import yaml
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, Response

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("voice-gw")

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/root/.hermes"))
DASHBOARD = os.environ.get("VOICE_DASHBOARD", "http://127.0.0.1:9119")
METRICS_DB = HERMES_HOME / "voice" / "metrics.db"
COOKIE_NAMES = ("hermes_session_at", "__Secure-hermes_session_at", "__Host-hermes_session_at")
AUTH_CACHE_S = 120.0


# ---------------------------------------------------------------- secrets ---
def _load_config() -> dict:
    return yaml.safe_load(open(HERMES_HOME / "config.yaml"))


_CFG = _load_config()
_BA = (_CFG.get("dashboard") or {}).get("basic_auth") or {}

for _line in (HERMES_HOME / ".env").read_text().splitlines():
    _line = _line.strip()
    if _line and not _line.startswith("#") and "=" in _line:
        k, v = _line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())

if not os.environ.get("ELEVENLABS_API_KEY"):
    log.warning("ELEVENLABS_API_KEY not set — TTS will fail until it is")


def _mint_session_token() -> str:
    """Mint the same HMAC access token the dashboard's basic provider mints."""
    raw = _BA.get("secret", "")
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
    payload = {"sub": _BA.get("username", "voice-gw"),
               "kind": "access", "exp": int(time.time()) + 3600}
    blob = json.dumps(payload, separators=(",", ":")).encode()
    sig = hmac_mod.new(secret, blob, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(blob + sig).decode()


_SESSION_TOKEN = _mint_session_token()
_SESSION_MINTED = time.time()


def _dash_headers() -> dict:
    global _SESSION_TOKEN, _SESSION_MINTED
    if time.time() - _SESSION_MINTED > 3000:      # rotate before the 1h exp
        _SESSION_TOKEN = _mint_session_token()
        _SESSION_MINTED = time.time()
    return {"Cookie": f"hermes_session_at={_SESSION_TOKEN}"}


def _remint() -> None:
    global _SESSION_TOKEN, _SESSION_MINTED
    _SESSION_TOKEN = _mint_session_token()
    _SESSION_MINTED = time.time()


# ---------------------------------------------------------------- metrics ---
METRICS_SCHEMA = """
CREATE TABLE IF NOT EXISTS turns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts REAL NOT NULL,
  surface TEXT NOT NULL,
  eou_ms REAL, stt_ms REAL, first_event_ms REAL,
  ttfb_audio_ms REAL, total_ms REAL,
  interruptions INTEGER DEFAULT 0,
  ok INTEGER DEFAULT 1, note TEXT
)
"""


def _db() -> sqlite3.Connection:
    METRICS_DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(METRICS_DB, timeout=10)
    conn.execute(METRICS_SCHEMA)
    return conn


def record_turn(surface: str, *, eou_ms=None, stt_ms=None, first_event_ms=None,
                ttfb_audio_ms=None, total_ms=None, interruptions=0, ok=1, note="") -> None:
    try:
        conn = _db()
        with conn:
            conn.execute(
                "INSERT INTO turns (ts, surface, eou_ms, stt_ms, first_event_ms,"
                " ttfb_audio_ms, total_ms, interruptions, ok, note)"
                " VALUES (?,?,?,?,?,?,?,?,?,?)",
                (time.time(), surface, eou_ms, stt_ms, first_event_ms,
                 ttfb_audio_ms, total_ms, interruptions, ok, note))
        conn.close()
    except Exception as exc:  # noqa: BLE001
        log.warning("metrics write failed: %s", exc)


# ---------------------------------------------------------------- auth ------
_auth_cache: Dict[str, float] = {}
_auth_client = httpx.AsyncClient(base_url=DASHBOARD, timeout=6.0)


def _cookie_from(request: Request) -> Optional[str]:
    for name in COOKIE_NAMES:
        v = request.cookies.get(name)
        if v:
            return v
    return None




def _bearer_from(request: "Request") -> Optional[str]:
    # Native (iOS) clients authenticate with the SAME stateless HMAC
    # access token the dashboard's basic provider mints (RFC 8252 flow):
    # Authorization: Bearer <token>. Verify locally — we already hold
    # the signing secret for _mint_session_token, so no dashboard
    # round-trip is needed. Same trust domain as the cookie path.
    auth = request.headers.get("authorization", "")
    parts = auth.split(" ", 1)
    if len(parts) != 2 or parts[0].strip().lower() != "bearer":
        return None
    return parts[1].strip() or None


def _bearer_valid(token: str) -> bool:
    # Verify kind=access + exp exactly like the basic provider's
    # verify_session: unsign (urlsafe b64 of json+sig), check exp.
    try:
        blob = base64.urlsafe_b64decode(token.encode())
        if len(blob) <= 32:
            return False
        raw, sig = blob[:-32], blob[-32:]
        if not hmac_mod.compare_digest(sig, hmac_mod.new(_secret_bytes(), raw, hashlib.sha256).digest()):
            return False
        payload = json.loads(raw)
        return payload.get("kind") == "access" and payload.get("exp", 0) > int(time.time())
    except Exception:
        return False


def _secret_bytes() -> bytes:
    # Same decode ladder as _mint_session_token.
    raw = _BA.get("secret", "")
    for decoder in (base64.b64decode, bytes.fromhex):
        try:
            cand = decoder(raw)
            if len(cand) >= 16:
                return cand
        except Exception:
            continue
    return raw.encode()

async def _cookie_valid(token: str) -> bool:
    key = hashlib.sha256(token.encode()).hexdigest()
    exp = _auth_cache.get(key)
    if exp and exp > time.time():
        return True
    try:
        r = await _auth_client.get("/api/control/voice/status",
                                   headers={"Cookie": f"hermes_session_at={token}"})
        ok = r.status_code == 200
    except Exception as exc:  # noqa: BLE001
        log.warning("auth check failed: %s", exc)
        ok = False
    if ok:
        _auth_cache[key] = time.time() + AUTH_CACHE_S
        if len(_auth_cache) > 256:
            for k in [k for k, e in _auth_cache.items() if e < time.time()]:
                _auth_cache.pop(k, None)
    return ok


PUBLIC_PATHS = {"/healthz", "/voice-gw/healthz"}

app = FastAPI(title="JARVIS Voice Gateway", docs_url=None, redoc_url=None)


@app.middleware("http")
async def _auth_gate(request: Request, call_next):
    path = request.url.path
    if path in PUBLIC_PATHS:
        return await call_next(request)
    token = _cookie_from(request)
    if token and await _cookie_valid(token):
        return await call_next(request)
    # Native-app bearer path (iOS): same HMAC token, no cookie.
    bearer = _bearer_from(request)
    if bearer and _bearer_valid(bearer):
        return await call_next(request)
    if path.rstrip("/") in ("/voice-gw", "/voice-gw/index.html") and "text/html" in request.headers.get("accept", ""):
        return RedirectResponse(url="/login?next=/voice-gw/", status_code=302)
    return JSONResponse({"error": "unauthorized"}, status_code=401)


_startup = time.time()


@app.get("/healthz")
@app.get("/voice-gw/healthz")
async def healthz():
    import brain as _b  # imported after app creation; resolved at call time
    eff = _b.effective_brain()
    return {"ok": True, "uptime_s": round(time.time() - _startup, 1),
            "configured_brain": _b.cfg("VOICE_BRAIN", _b.BRAIN), "brain": eff,
            "realtime": eff == "openai-realtime",
            "openai_status": _b._probe.get("why") or ("ok" if _b._probe.get("ok") else "unprobed"),
            "fireworks_probe_ms": _b._fw_probe.get("ms"), "fireworks_ok": _b._fw_probe.get("ok"),
            "model": (_b.cfg("VOICE_OPENAI_MODEL", _b.OPENAI_REALTIME_MODEL) if eff == "openai-realtime"
                      else _b.cfg("VOICE_FIREWORKS_MODEL", _b.FIREWORKS_MODEL).rsplit("/", 1)[-1]),
            "surface": ["webrtc", "discord"], "version": "v2"}


@app.get("/voice-gw/api/metrics")
async def metrics_summary():
    try:
        conn = _db()
        rows = conn.execute(
            "SELECT surface, COUNT(*), AVG(total_ms), MIN(total_ms), MAX(total_ms)"
            " FROM turns WHERE total_ms IS NOT NULL AND ts > ? GROUP BY surface",
            (time.time() - 7 * 86400,)).fetchall()
        recent = conn.execute(
            "SELECT ts, surface, total_ms, note FROM turns WHERE total_ms IS NOT NULL"
            " ORDER BY ts DESC LIMIT 20").fetchall()
        conn.close()
        return {"surfaces": [{"surface": r[0], "turns": r[1], "avg_ms": r[2],
                              "min_ms": r[3], "max_ms": r[4]} for r in rows],
                "recent": [{"ts": r[0], "surface": r[1], "ms": r[2], "note": r[3]} for r in recent],
                "sessions": _sessions.list()}
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc)}


VOICE_PAGE = Path(__file__).parent / "voice_page.html"


@app.get("/voice-gw/")
@app.get("/voice-gw/index.html")
async def voice_page():
    if VOICE_PAGE.exists():
        return FileResponse(VOICE_PAGE, media_type="text/html",
                            headers={"Cache-Control": "no-store"})
    raise HTTPException(404, "voice page missing")


# --- pipeline wiring ----------------------------------------------------------
from pipecat.transports.smallwebrtc.connection import IceServer, SmallWebRTCConnection
from pipecat.transports.smallwebrtc.request_handler import (
    ConnectionMode, SmallWebRTCRequest, SmallWebRTCRequestHandler)

import brain as brain_mod
import session as session_mod
from session import VoiceSessionManager

dashboard = brain_mod.Dashboard(_dash_headers, _remint)
session_mod.setup(dashboard, record_turn)

_sessions = VoiceSessionManager()
_ice = [IceServer(urls=os.environ.get("VOICE_STUN", "stun:stun.l.google.com:19302"))]
_handler = SmallWebRTCRequestHandler(ice_servers=_ice, connection_mode=ConnectionMode.MULTIPLE)


@app.post("/voice-gw/api/offer")
async def voice_gw_offer(request: Request):
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        raise HTTPException(400, "offer body is not valid JSON")
    if not isinstance(body, dict) or not str(body.get("sdp") or "").strip():
        # Malformed offers used to 500 (fault #4 in voice-failure-diagnosis.md)
        # — 400 with the exact missing piece so client bugs don't read as
        # "server error" in monitoring.
        raise HTTPException(400, "offer body must be {\"sdp\": <offer SDP>, \"type\": \"offer\"} (sdp missing/empty)")
    try:
        req = SmallWebRTCRequest.from_dict(body)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(400, f"offer rejected: {exc}")

    # Native clients (iOS) pass {surface, reason} via request_data; the web
    # page sends none and stays "cc_pwa". The reason gives the voice session
    # context for why the call was placed (VoIP push payload.reason).
    rd = req.request_data if isinstance(req.request_data, dict) else {}
    surface = str(rd.get("surface") or "cc_pwa")
    reason = str(rd.get("reason") or "").strip()

    async def on_connection(connection: SmallWebRTCConnection):
        s = await _sessions.start(surface, connection)
        if reason:
            # Queue after start; the greeting fires on client-connected, so the
            # reason lands as a follow-up line right after the greeting.
            asyncio.get_running_loop().call_later(
                6.0, lambda: asyncio.ensure_future(
                    s.say(f"(Automatic notice: this is a JARVIS-initiated call. Reason: {reason}. "
                          f"Speak the reason in one short sentence NOW, then immediately say a brief "
                          f"goodbye and call the end_call tool. Do not use any other tool. Do not "
                          f"wait for a reply — nobody will answer.)")
                ) if not s.closed else None
            )
            # Deterministic backstop: the realtime model sometimes answers the
            # notice with a wrong tool (seen 2026-09-23: call_enrique instead
            # of end_call), leaving the "initiated" call on the line forever.
            # A reasoned call is fire-and-forget — hang it up server-side.
            def _auto_stop(session=s):
                if not session.closed:
                    asyncio.ensure_future(session.stop())
            asyncio.get_running_loop().call_later(40.0, _auto_stop)

    answer = await _handler.handle_web_request(request=req, webrtc_connection_callback=on_connection)
    return answer


@app.post("/webrtc/offer")
async def webrtc_offer(request: Request):
    return await voice_gw_offer(request)


@app.post("/voice-gw/api/say")
async def voice_gw_say(request: Request):
    """Typed input: the page's text box, and headless tests."""
    body = await request.json()
    s = _sessions.get(body.get("pc_id"))
    if s is None or s.closed:
        raise HTTPException(404, "no live session")
    await s.say(str(body.get("text") or ""))
    return {"ok": True, "pc_id": s.pc_id, "thread": s.thread_id}


@app.get("/voice-gw/api/diag")
async def voice_gw_diag():
    """Times the outbound path FROM INSIDE this process (DNS, TLS/connect,
    a 1-token completion) — to tell provider slowness from something local."""
    import socket
    out: Dict[str, Any] = {}
    loop = asyncio.get_running_loop()
    t0 = time.time()
    try:
        infos = await loop.getaddrinfo("api.fireworks.ai", 443, type=socket.SOCK_STREAM)
        out["dns_ms"] = round((time.time() - t0) * 1000)
        out["dns_addrs"] = sorted({i[4][0] for i in infos})[:6]
    except Exception as exc:  # noqa: BLE001
        out["dns_error"] = str(exc)
    key = os.environ.get("FIREWORKS_API_KEY", "")
    for label, force_v4 in (("default", False), ("ipv4", True)):
        t0 = time.time()
        try:
            transport = httpx.AsyncHTTPTransport(local_address="0.0.0.0") if force_v4 else None
            async with httpx.AsyncClient(timeout=30.0, transport=transport) as c:
                r = await c.get("https://api.fireworks.ai/inference/v1/models",
                                headers={"Authorization": "Bearer " + key})
                t1 = time.time()
                r2 = await c.post("https://api.fireworks.ai/inference/v1/chat/completions",
                                  headers={"Authorization": "Bearer " + key},
                                  json={"model": "accounts/fireworks/models/glm-5p3-flash",
                                        "max_tokens": 1, "reasoning_effort": "low",
                                        "messages": [{"role": "user", "content": "hi"}]})
            out[label] = {"connect_get_ms": round((t1 - t0) * 1000), "get_status": r.status_code,
                          "chat_ms": round((time.time() - t1) * 1000), "chat_status": r2.status_code}
        except Exception as exc:  # noqa: BLE001
            out[label] = {"error": f"{type(exc).__name__}: {exc}"[:200]}
    out["threads"] = __import__("threading").active_count()
    return out


@app.get("/voice-gw/api/sessions")
async def voice_gw_sessions():
    return {"sessions": _sessions.list()}


@app.post("/voice-gw/api/hangup")
async def voice_gw_hangup(request: Request):
    body = await request.json() if int(request.headers.get("content-length", "0") or 0) else {}
    s = _sessions.get(body.get("pc_id"))
    if s is None:
        return {"ok": False}
    await s.stop()
    return {"ok": True}


# --- Discord surface ---------------------------------------------------------
_discord = None


async def _start_discord() -> None:
    global _discord
    if os.environ.get("VOICE_GW_DISCORD", "1") not in ("1", "true", "yes"):
        log.info("Discord surface disabled by VOICE_GW_DISCORD")
        return
    # A dedicated bot token for voice is preferred: sharing DISCORD_BOT_TOKEN with
    # the Hermes Discord (text) bot makes Discord drop this voice connection
    # every few hours (both sessions identify with the same bot user).
    token = os.environ.get("DISCORD_VOICE_BOT_TOKEN", "") or os.environ.get("DISCORD_BOT_TOKEN", "")
    if not token:
        log.warning("DISCORD_BOT_TOKEN not set — Discord surface disabled")
        return
    if not os.environ.get("DISCORD_VOICE_BOT_TOKEN"):
        log.warning("Discord voice is sharing DISCORD_BOT_TOKEN with the Hermes Discord bot; "
                    "set DISCORD_VOICE_BOT_TOKEN (a second bot) to stop periodic voice drops")
    allowed_raw = os.environ.get("DISCORD_ALLOWED_USERS", "")
    try:
        allowed = {int(x) for x in re.findall(r"\d+", allowed_raw)}
    except Exception:  # noqa: BLE001
        allowed = set()

    async def session_factory(meta: dict):
        return await _sessions.start_custom(
            "discord", key=f"discord:{meta.get('channel')}",
            transport_pair=(meta["input"], meta["output"]))

    def in_rate() -> int:
        # OpenAI Realtime wants 24 kHz PCM16 (the service does not resample);
        # the Whisper cascade runs at 16 kHz.
        return 24000 if brain_mod.is_realtime() else 16000

    try:
        from discord_adapter import DiscordVoiceAdapter
        _discord = DiscordVoiceAdapter(token, allowed, session_factory, in_rate_fn=in_rate)
        await _discord.start()
        log.info("discord surface starting (allowed users: %s)", sorted(allowed))
    except Exception as exc:  # noqa: BLE001
        log.error("discord surface failed to start: %s", exc)


@app.on_event("startup")
async def _on_startup():
    if brain_mod.cfg("VOICE_BRAIN", brain_mod.BRAIN) in ("openai-realtime", "openai", "realtime") \
            and not os.environ.get("OPENAI_API_KEY"):
        log.error("VOICE_BRAIN=openai-realtime but OPENAI_API_KEY is missing - calls fall back to "
                  "the cascade until it is set in %s/.env", HERMES_HOME)
    eff = await asyncio.get_running_loop().run_in_executor(None, brain_mod.effective_brain)
    log.info("effective voice brain at startup: %s", eff)
    if eff != "openai-realtime":
        # Warm the Whisper model so the first turn of the first call is not slow.
        try:
            await asyncio.get_running_loop().run_in_executor(None, session_mod.get_stt)
        except Exception as exc:  # noqa: BLE001
            log.warning("STT warm-up failed: %s", exc)
    await _start_discord()


@app.post("/voice-gw/api/discord/join")
async def discord_join(request: Request):
    if _discord is None or getattr(_discord, "_client", None) is None:
        raise HTTPException(503, "discord surface disabled")
    body = await request.json() if int(request.headers.get("content-length", "0") or 0) else {}
    channel_id = int(body.get("channel_id") or 0)
    if not channel_id:
        for g in _discord._client.guilds:
            vc = next((c for c in g.voice_channels), None)
            if vc:
                channel_id = vc.id
                break
    if not channel_id:
        raise HTTPException(404, "no voice channel found")
    await _discord.join_channel(channel_id)
    return {"ok": True, "channel_id": channel_id}


@app.post("/voice-gw/api/discord/leave")
async def discord_leave():
    if _discord is None:
        raise HTTPException(503, "discord surface disabled")
    await _discord.leave()
    return {"ok": True}


@app.get("/voice-gw/api/discord/status")
async def discord_status():
    if _discord is None:
        return {"enabled": False}
    v = getattr(_discord, "_voice", None)
    return {"enabled": True, "connected": bool(v and v.is_connected()),
            "channel": getattr(getattr(v, "channel", None), "name", None),
            "own_token": bool(os.environ.get("DISCORD_VOICE_BOT_TOKEN"))}


@app.on_event("shutdown")
async def _shutdown():
    await _sessions.close_all()
