"""JARVIS v2 chat adapter — the server half of the iOS v2 chat contract.

Implements exactly the two routes in Packages/JarvisKit/.../Fixtures/contract.json:

  POST /v1/conversations/{cid}/messages   {message_id, content} -> 202
  GET  /v1/conversations/{cid}/events     SSE, Last-Event-ID resume

Each user message becomes one FULL JARVIS turn (tools, memory, delegation)
via `hermes chat -q ... -Q -c ios-v2-<cid> --create-if-missing`, so every app
conversation is its own Hermes session (visible in the dashboard, source tag
`ios-v2`). The answer is published on the conversation's event stream as
message_start -> token -> done (or error).

Auth: the app's dashboard bearer is forwarded to the dashboard itself
(GET /api/control/vitals) — 200 means valid. No secret lives here.

Durability: every event is appended to <STATE_DIR>/<cid>.jsonl with a
monotonic id, so reconnects (Last-Event-ID) replay exactly what was missed,
across restarts. message_ids are idempotent: a replayed outbox POST never
runs a second turn.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import time
import uuid
from pathlib import Path
from typing import Dict, List, Optional

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

log = logging.getLogger("v2_chat")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

DASHBOARD = os.environ.get("V2_CHAT_DASHBOARD", "http://127.0.0.1:9119")
HERMES_BIN = os.environ.get("V2_CHAT_HERMES_BIN", "hermes")
STATE_DIR = Path(os.environ.get("V2_CHAT_STATE_DIR", "/root/.hermes/ios-v2-chat"))
TURN_TIMEOUT_S = int(os.environ.get("V2_CHAT_TURN_TIMEOUT_S", "1800"))
HEARTBEAT_S = 15
AUTH_CACHE_S = 60
MAX_CONTENT = 20_000

STATE_DIR.mkdir(parents=True, exist_ok=True)
app = FastAPI(title="jarvis-v2-chat")

_UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_auth_cache: Dict[str, float] = {}
_http = httpx.AsyncClient(timeout=10)


# --- auth ---------------------------------------------------------------------

async def require_auth(authorization: Optional[str]) -> None:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer")
    key = hashlib.sha256(authorization.encode()).hexdigest()
    now = time.time()
    if _auth_cache.get(key, 0) > now:
        return
    try:
        r = await _http.get(f"{DASHBOARD}/api/control/vitals",
                            headers={"Authorization": authorization})
    except httpx.HTTPError:
        raise HTTPException(status_code=503, detail="auth backend unreachable")
    if r.status_code != 200:
        raise HTTPException(status_code=401, detail="invalid bearer")
    _auth_cache[key] = now + AUTH_CACHE_S


def norm_cid(cid: str) -> str:
    if not _UUID_RE.match(cid):
        raise HTTPException(status_code=400, detail="conversation id must be a UUID")
    return cid.lower()


# --- per-conversation event log ----------------------------------------------

class Conversation:
    def __init__(self, cid: str):
        self.cid = cid
        self.path = STATE_DIR / f"{cid}.jsonl"
        self.events: List[dict] = []
        self.seen_messages: set = set()
        self.cond = asyncio.Condition()
        self.turn_lock = asyncio.Lock()
        if self.path.exists():
            for line in self.path.read_text(encoding="utf-8").splitlines():
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                self.events.append(ev)
                if ev.get("reply_to"):
                    self.seen_messages.add(ev["reply_to"])

    @property
    def last_id(self) -> int:
        return self.events[-1]["id"] if self.events else 0

    async def publish(self, kind: str, payload: str, reply_to: Optional[str] = None) -> dict:
        async with self.cond:
            ev = {"id": self.last_id + 1, "kind": kind, "payload": payload, "ts": time.time()}
            if reply_to:
                ev["reply_to"] = reply_to
            self.events.append(ev)
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(ev, ensure_ascii=False) + "\n")
            self.cond.notify_all()
            return ev


_convs: Dict[str, Conversation] = {}


def conv(cid: str) -> Conversation:
    c = _convs.get(cid)
    if c is None:
        c = _convs[cid] = Conversation(cid)
    return c


# --- the JARVIS turn ------------------------------------------------------------

async def run_turn(c: Conversation, user_message_id: str, content: str) -> None:
    async with c.turn_lock:  # one turn at a time per conversation, in order
        reply_id = str(uuid.uuid4())
        start = json.dumps({"message_id": reply_id})
        await c.publish("message_start", start, reply_to=user_message_id)
        argv = [HERMES_BIN, "chat", "-q", content, "-Q",
                "-c", f"ios-v2-{c.cid}", "--create-if-missing", "--source", "ios-v2"]
        t0 = time.time()
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv, stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                cwd=str(Path.home()), env={**os.environ, "NO_COLOR": "1", "TERM": "dumb"})
            out, err = await asyncio.wait_for(proc.communicate(), timeout=TURN_TIMEOUT_S)
            text = out.decode("utf-8", "replace").strip()
            if proc.returncode != 0 or not text:
                tail = err.decode("utf-8", "replace").strip().splitlines()[-3:]
                raise RuntimeError(f"hermes rc={proc.returncode}: {' | '.join(tail)[:300]}")
            await c.publish("token", text)
            await c.publish("done", json.dumps({"message_id": reply_id}))
            log.info("turn ok cid=%s msg=%s took=%.1fs chars=%d",
                     c.cid, user_message_id, time.time() - t0, len(text))
        except Exception as exc:  # noqa: BLE001 — every failure must reach the app
            try:
                proc.kill()  # type: ignore[possibly-undefined]
            except Exception:  # noqa: BLE001
                pass
            reason = "JARVIS took too long" if isinstance(exc, asyncio.TimeoutError) else str(exc)
            log.warning("turn failed cid=%s msg=%s: %s", c.cid, user_message_id, reason)
            await c.publish("error", json.dumps({"message_id": reply_id, "message": reason[:300]}))


# --- routes ---------------------------------------------------------------------

@app.get("/v1/conversations/health")
async def health():
    return {"ok": True, "conversations": len(_convs), "state_dir": str(STATE_DIR)}


@app.post("/v1/conversations/{cid}/messages", status_code=202)
async def post_message(cid: str, request: Request,
                       authorization: Optional[str] = Header(None)):
    await require_auth(authorization)
    cid = norm_cid(cid)
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="body must be JSON")
    message_id = str(body.get("message_id") or "").strip().lower()
    content = str(body.get("content") or "").strip()
    if not _UUID_RE.match(message_id):
        raise HTTPException(status_code=400, detail="message_id must be a UUID")
    if not content:
        raise HTTPException(status_code=400, detail="empty content")
    content = content[:MAX_CONTENT]
    c = conv(cid)
    reply = {"message_id": message_id, "conversation_id": cid, "accepted": True}
    if message_id in c.seen_messages:  # outbox replay — never a second turn
        return JSONResponse(reply, status_code=202)
    c.seen_messages.add(message_id)
    asyncio.create_task(run_turn(c, message_id, content))
    return JSONResponse(reply, status_code=202)


def _sse(ev: dict) -> str:
    lines = [f"id: {ev['id']}", f"event: {ev['kind']}"]
    lines += [f"data: {part}" for part in str(ev["payload"]).split("\n")]
    return "\n".join(lines) + "\n\n"


@app.get("/v1/conversations/{cid}/events")
async def events(cid: str, authorization: Optional[str] = Header(None),
                 last_event_id: Optional[str] = Header(None)):
    await require_auth(authorization)
    cid = norm_cid(cid)
    c = conv(cid)
    try:
        cursor = int(last_event_id or 0)
    except ValueError:
        cursor = 0

    async def gen():
        nonlocal cursor
        yield ": connected\n\n"
        while True:
            pending = [e for e in c.events if e["id"] > cursor]
            for ev in pending:
                yield _sse(ev)
                cursor = ev["id"]
            async with c.cond:
                try:
                    await asyncio.wait_for(
                        c.cond.wait_for(lambda: c.last_id > cursor), timeout=HEARTBEAT_S)
                except asyncio.TimeoutError:
                    yield ": hb\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
