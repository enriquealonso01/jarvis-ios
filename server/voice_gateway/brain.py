#!/usr/bin/env python3
"""The voice brain: a streaming, tool-calling LLM that IS the conversation.

Why this exists (2026-09-16 rebuild): the previous gateway used the dashboard's
turn engine as its "LLM" — every utterance went through a non-streaming Z.AI
classify call (2.7–4 s each, up to three of them), then a JSON reply, then TTS.
"Hey Jarvis" took 5–14 s. Here the model itself streams tokens straight into
TTS (first audio ≈ 1 s), and the full Hermes agent becomes a TOOL it can call
in the background while the conversation carries on.

Providers (env VOICE_BRAIN): fireworks (default, ~0.6 s TTFT for the same
GLM-5.3-flash the Z.AI plan serves at ~3 s), zai (the plan endpoint — slow,
kept as an option because Enrique prefers Z.AI when it is fast enough),
anthropic (needs ANTHROPIC_API_KEY + `uv pip install anthropic` in the venv).
"""
from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, List, Optional
from zoneinfo import ZoneInfo

import httpx
from loguru import logger

from pipecat.adapters.schemas.direct_function import tool_options
from pipecat.adapters.schemas.function_schema import FunctionSchema
from pipecat.adapters.schemas.tools_schema import ToolsSchema
from pipecat.frames.frames import (FunctionCallResultProperties, InterruptionFrame,
                                   LLMMessagesAppendFrame)
from pipecat.services.llm_service import FunctionCallParams

log = logging.getLogger("voice-gw.brain")

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/root/.hermes"))
DASHBOARD = os.environ.get("VOICE_DASHBOARD", "http://127.0.0.1:9119")
TZ = ZoneInfo(os.environ.get("VOICE_TZ", "America/New_York"))

VOICE_ENV_PATH = Path(os.environ.get("VOICE_ENV_PATH", "/opt/voice-gw/voice.env"))
VOICE_SRC_DIR = Path(os.environ.get("VOICE_SRC_DIR", "/opt/voice-gw"))
VOICE_RULES_PATH = HERMES_HOME / "jarvis" / "voice_rules.md"
SETTABLE_KEYS = ("VOICE_BRAIN", "VOICE_OPENAI_MODEL", "VOICE_OPENAI_VOICE", "VOICE_OPENAI_EAGERNESS",
                 "VOICE_OPENAI_REASONING", "VOICE_OPENAI_SPEED", "VOICE_GREETING",
                 "VOICE_FIREWORKS_MODEL", "VOICE_STT_MODEL", "VOICE_TTS_MODEL", "VOICE_TTS_VOICE_ID", "VOICE_GW_DISCORD")


def _load_voice_env() -> Dict[str, str]:
    """voice.env, parsed the way systemd does (KEY=value, optional quotes)."""
    out: Dict[str, str] = {}
    try:
        for line in VOICE_ENV_PATH.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[k.strip()] = v
    except OSError:
        pass
    return out


def cfg(key: str, default: str = "") -> str:
    """Live setting: voice.env on disk wins over the process environment, so a
    change the agent makes to itself applies on the next call, no restart."""
    v = _load_voice_env().get(key)
    if v is None:
        v = os.environ.get(key)
    return default if v is None or v == "" else v


def set_cfg(key: str, value: str) -> None:
    key = key.strip().upper()
    if key not in SETTABLE_KEYS:
        raise ValueError(f"{key} is not a settable voice key ({', '.join(SETTABLE_KEYS)})")
    value = str(value).strip().replace("\n", " ")
    lines = []
    try:
        lines = VOICE_ENV_PATH.read_text(encoding="utf-8").splitlines()
    except OSError:
        pass
    quoted = f'"{value}"' if (" " in value or "," in value) else value
    done = False
    for i, line in enumerate(lines):
        if line.strip().startswith(key + "="):
            lines[i] = f"{key}={quoted}"
            done = True
    if not done:
        lines.append(f"{key}={quoted}")
    VOICE_ENV_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


BRAIN = os.environ.get("VOICE_BRAIN", "fireworks").strip().lower()
FIREWORKS_MODEL = os.environ.get("VOICE_FIREWORKS_MODEL", "accounts/fireworks/models/glm-5p3-flash")
ZAI_MODEL = os.environ.get("VOICE_ZAI_MODEL", "glm-5.3-flash")
ZAI_BASE = os.environ.get("VOICE_ZAI_BASE", "https://api.z.ai/api/coding/paas/v4")
ANTHROPIC_MODEL = os.environ.get("VOICE_ANTHROPIC_MODEL", "claude-sonnet-5")
# OpenAI Realtime (speech-to-speech): the model hears and speaks directly, no
# Whisper/ElevenLabs in the loop. Voice = one of OpenAI's (the ElevenLabs
# "JARVIS" clone cannot be used here). Pipecat 1.10 defaults to gpt-realtime-2.1.
OPENAI_REALTIME_MODEL = os.environ.get("VOICE_OPENAI_MODEL", "gpt-realtime-2.1-mini")
OPENAI_VOICE = os.environ.get("VOICE_OPENAI_VOICE", "ash")
OPENAI_EAGERNESS = os.environ.get("VOICE_OPENAI_EAGERNESS", "low")       # semantic VAD: low = let him pause
OPENAI_REASONING = os.environ.get("VOICE_OPENAI_REASONING", "low")       # 2.x models only
OPENAI_SPEED = float(os.environ.get("VOICE_OPENAI_SPEED", "1.0"))
IS_REALTIME = BRAIN in ("openai-realtime", "openai", "realtime")

_probe: Dict[str, Any] = {"ok": None, "ts": 0.0, "why": ""}
PROBE_TTL_S = 600.0


def _openai_credits_ok(key: str) -> bool:
    """One-token chat completion: catches insufficient_quota / bad key before a
    call is built on a socket that OpenAI will close with 1013. Cached 10 min."""
    now = time.time()
    if _probe["ok"] is not None and now - _probe["ts"] < PROBE_TTL_S:
        return bool(_probe["ok"])
    ok, why = False, ""
    try:
        r = httpx.post("https://api.openai.com/v1/chat/completions",
                       headers={"Authorization": "Bearer " + key},
                       json={"model": "gpt-4o-mini", "max_tokens": 1,
                             "messages": [{"role": "user", "content": "hi"}]}, timeout=15.0)
        ok = r.status_code == 200
        if not ok:
            try:
                why = str(r.json().get("error", {}).get("code") or r.status_code)
            except Exception:  # noqa: BLE001
                why = str(r.status_code)
    except Exception as exc:  # noqa: BLE001
        why = f"{type(exc).__name__}"
    _probe.update(ok=ok, ts=now, why=why)
    if not ok:
        logger.warning("OpenAI not usable right now ({}); voice falls back to the cascade", why)
    return ok


_fw_probe: Dict[str, Any] = {"ok": None, "ts": 0.0, "ms": None}
FW_PROBE_TTL_S = 90.0
FW_SLOW_MS = float(os.environ.get("VOICE_FW_SLOW_MS", "3500"))


def _fireworks_fast(key: str) -> bool:
    """One-token completion with a short deadline. Fireworks stalled 10-30 s per
    request for ~20 min on 2026-09-16 while its metadata endpoint stayed fast;
    when that happens the cascade is better off on Z.AI (~3 s) than waiting."""
    now = time.time()
    if _fw_probe["ok"] is not None and now - _fw_probe["ts"] < FW_PROBE_TTL_S:
        return bool(_fw_probe["ok"])
    t0 = time.time()
    ok = False
    try:
        r = httpx.post("https://api.fireworks.ai/inference/v1/chat/completions",
                       headers={"Authorization": "Bearer " + key},
                       json={"model": cfg("VOICE_FIREWORKS_MODEL", FIREWORKS_MODEL),
                             "max_tokens": 1, "reasoning_effort": "low",
                             "messages": [{"role": "user", "content": "hi"}]},
                       timeout=FW_SLOW_MS / 1000.0)
        ok = r.status_code == 200
    except Exception:  # noqa: BLE001 - timeout == slow == not ok
        ok = False
    ms = round((time.time() - t0) * 1000)
    _fw_probe.update(ok=ok, ts=now, ms=ms)
    if not ok:
        logger.warning("Fireworks slow/unavailable ({} ms, limit {:.0f}); cascade uses Z.AI", ms, FW_SLOW_MS)
    return ok


def effective_brain() -> str:
    """What THIS call will run on: the configured brain, unless it is OpenAI and
    the account cannot be used (no credits / bad key) -> cascade; and the cascade
    itself uses Z.AI while Fireworks is stalling."""
    want = cfg("VOICE_BRAIN", BRAIN).strip().lower()
    if want in ("openai-realtime", "openai", "realtime"):
        key = os.environ.get("OPENAI_API_KEY", "")
        if key and _openai_credits_ok(key):
            return "openai-realtime"
        want = "fireworks"
    if want == "fireworks":
        fk = os.environ.get("FIREWORKS_API_KEY", "")
        zk = os.environ.get("ZAI_API_KEY", "")
        if fk and zk and not _fireworks_fast(fk):
            return "zai"
    return want or "fireworks"


def is_realtime() -> bool:
    return effective_brain() == "openai-realtime"

ASK_JARVIS_TIMEOUT_S = float(os.environ.get("VOICE_ASK_TIMEOUT_S", "900"))
TOOL_TIMEOUT_S = float(os.environ.get("VOICE_TOOL_TIMEOUT_S", "12"))

# Ring Enrique's iPhone via the JARVIS-iOS push bridge (jarvis-ios backlog #8).
_BRIDGE_URL = os.environ.get("JARVIS_IOS_BRIDGE_URL", "http://127.0.0.1:9160")
_BRIDGE_SECRET = Path("/opt/jarvis-ios-bridge/shared_secret")

_SECRETISH = ("token", "secret", "password", "credential", "api key", "api_key",
              "pc bridge", "127.0.0.1", "bearer")


# ----------------------------------------------------------------- dashboard --
class Dashboard:
    """Loopback client for the Control Center backend (Tier-1 tools, the full
    agent, transcript recording). Auth = the same HMAC session token the
    gateway mints (see gateway.py)."""

    def __init__(self, headers_fn: Callable[[], Dict[str, str]],
                 on_401: Callable[[], None]):
        self._client = httpx.AsyncClient(base_url=DASHBOARD, timeout=30.0)
        self._headers = headers_fn
        self._on_401 = on_401

    async def _req(self, method: str, path: str, *, json_body: Any = None,
                   timeout: float = 30.0, params: Dict[str, Any] | None = None) -> httpx.Response:
        r = await self._client.request(method, path, headers=self._headers(),
                                       json=json_body, timeout=timeout, params=params)
        if r.status_code == 401:
            self._on_401()
            r = await self._client.request(method, path, headers=self._headers(),
                                           json=json_body, timeout=timeout, params=params)
        return r

    async def tools(self) -> List[Dict[str, Any]]:
        try:
            r = await self._req("GET", "/api/control/voice/tools", timeout=8.0)
            r.raise_for_status()
            return list(r.json().get("tools") or [])
        except Exception as exc:  # noqa: BLE001
            log.warning("tier-1 tool list unavailable: %s", exc)
            return []

    async def run_tool(self, name: str, args: Dict[str, Any]) -> str:
        r = await self._req("POST", "/api/control/voice/tool",
                            json_body={"name": name, "args": args}, timeout=TOOL_TIMEOUT_S + 3)
        r.raise_for_status()
        return str(r.json().get("result") or "")

    async def context(self) -> Dict[str, Any]:
        try:
            r = await self._req("GET", "/api/control/voice/context", timeout=8.0)
            r.raise_for_status()
            return dict(r.json())
        except Exception as exc:  # noqa: BLE001
            log.warning("voice context unavailable (%s); reading files directly", exc)
            return {}

    async def record(self, thread_id: str, user: str, assistant: str) -> None:
        try:
            await self._req("POST", "/api/control/voice/record",
                            json_body={"thread_id": thread_id, "user": user,
                                       "assistant": assistant}, timeout=8.0)
        except Exception as exc:  # noqa: BLE001
            log.debug("record failed: %s", exc)

    async def presence(self, thread_id: str) -> None:
        """Tell the engine he is AT THE MIC on this thread. Without this the
        engine's is_live() is False, so it treats every ask_jarvis result as
        "he walked away": no answer event, straight to WhatsApp."""
        try:
            await self._req("POST", "/api/control/voice/presence",
                            json_body={"thread_id": thread_id, "mic_open": True,
                                       "tab_visible": True}, timeout=5.0)
        except Exception as exc:  # noqa: BLE001
            log.debug("presence failed: %s", exc)

    async def interject(self, turn_id: str, text: str) -> None:
        try:
            await self._req("POST", "/api/control/voice/interject",
                            json_body={"turn_id": turn_id, "text": text}, timeout=15.0)
        except Exception as exc:  # noqa: BLE001
            log.debug("interject failed: %s", exc)

    async def result(self, turn_id: str) -> Dict[str, Any]:
        try:
            r = await self._req("GET", f"/api/control/voice/result/{turn_id}", timeout=8.0)
            return dict(r.json())
        except Exception:  # noqa: BLE001
            return {}

    async def start_turn(self, text: str, thread_id: str) -> Dict[str, Any]:
        r = await self._req("POST", "/api/control/voice/turn",
                            json_body={"text": text, "thread_id": thread_id}, timeout=60.0)
        r.raise_for_status()
        return dict(r.json())

    async def events(self, turn_id: str):
        """Yield (event, payload) from the turn's SSE feed, polling as fallback."""
        url = f"/api/control/voice/events/{turn_id}"
        try:
            async with self._client.stream("GET", url, headers=self._headers(),
                                           timeout=httpx.Timeout(60.0, read=ASK_JARVIS_TIMEOUT_S)) as r:
                if r.status_code != 200:
                    return
                name = None
                async for raw in r.aiter_lines():
                    if raw.startswith("event:"):
                        name = raw.split(":", 1)[1].strip()
                    elif raw.startswith("data:") and name:
                        try:
                            ev = json.loads(raw[5:].strip() or "{}")
                        except json.JSONDecodeError:
                            continue
                        yield name, ev
                        if name == "end":
                            return
        except Exception as exc:  # noqa: BLE001
            log.warning("SSE failed (%s); polling", exc)
            since, deadline = 0, time.time() + ASK_JARVIS_TIMEOUT_S
            while time.time() < deadline:
                try:
                    r = await self._req("GET", f"/api/control/voice/poll/{turn_id}",
                                        params={"since": since}, timeout=10.0)
                    data = r.json()
                    for ev in data.get("events", []):
                        since = max(since, int(ev.get("seq", 0)))
                        yield ev.get("type", "event"), ev
                        if ev.get("type") == "end":
                            return
                    if data.get("done"):
                        return
                except Exception:  # noqa: BLE001
                    pass
                await asyncio.sleep(0.5)


# ------------------------------------------------------------ system prompt --
def now_hint() -> str:
    now = datetime.now(TZ)
    return now.strftime("It is %A, %B %-d %Y, %-I:%M %p") + f" ({TZ.key})."


def _profile_from_file() -> str:
    """Fallback if the dashboard context route is missing: USER.md minus
    anything operational/secret-adjacent."""
    try:
        raw = (HERMES_HOME / "memories" / "USER.md").read_text(encoding="utf-8")
    except OSError:
        return ""
    keep = []
    for seg in raw.split("§"):
        s = " ".join(seg.split())
        if not s or any(k in s.lower() for k in _SECRETISH):
            continue
        keep.append(s)
    return " ".join(keep)[:1400]


def _rolling_context() -> str:
    """What JARVIS (main) is mid-flight on right now — written by the main
    agent to memories/voice_context.md. One paragraph, refreshed often."""
    try:
        raw = (HERMES_HOME / "memories" / "voice_context.md").read_text(encoding="utf-8")
    except OSError:
        return ""
    return " ".join(raw.split())[:500]


# Instructions in MEMORY.md that are about WRITTEN channels and must never reach
# a call: on 2026-09-16 the digest told the voice model "Thread tag at BOTTOM of
# every reply" and it dutifully said "Thread tag: call active" out loud, twice,
# then told him it had not. Dropped sentence by sentence, not segment by segment,
# because these sit inside segments that are otherwise useful.
_WRITTEN_CHANNEL_ONLY = ("thread tag", "voice-note transcript", "send files over long text")


def _memory_from_file() -> str:
    """My live working memory (MEMORY.md): projects, decisions, crons, lessons.
    Same §-filtered shape as the profile — this is what makes voice-JARVIS the
    SAME JARVIS he texts, not a stranger with his bio."""
    try:
        raw = (HERMES_HOME / "memories" / "MEMORY.md").read_text(encoding="utf-8")
    except OSError:
        return ""
    keep = []
    for seg in raw.split("§"):
        s = " ".join(seg.split())
        if not s or any(k in s.lower() for k in _SECRETISH):
            continue
        sentences = [x for x in re.split(r"(?<=[.;]) ", s)
                     if not any(k in x.lower() for k in _WRITTEN_CHANNEL_ONLY)]
        s = " ".join(sentences).strip()
        if s:
            keep.append(s)
    return " ".join(keep)[:1100]


def agent_thread_id(thread_id: str) -> str:
    """The engine thread ask_jarvis works on: SEPARATE from the call's own
    thread (the spoken exchange, which the session records). Until 2026-09-18
    both shared one thread, so every directive prompt the gateway sent the
    engine showed up as HIS line in the transcript, the nightly recaps and
    past_voice_talks. The refresh cron globs vg-*, so the agent- prefix keeps
    these out of recaps; the session heartbeats presence on both ids."""
    return "agent-" + thread_id


# Dashboard tool descriptions the voice model over-triggers on. 2026-09-18: mini took
# "I've been thinking about Krendora" as a planning request (plan_with_me) twice.
TOOL_DESC_OVERRIDES = {
    "plan_with_me": ("Start a step-by-step planning session ONLY when he explicitly asks to plan "
                     "(\"let's plan\", \"make a plan\", \"plan this with me\", \"help me plan\"). "
                     "Never for a conversation, an opinion, a status question or \"I've been "
                     "thinking about X\": those are answered by speaking, with kb_lookup."),
}

INSTANT_TOOLS = ("cron_status", "control_center", "project_brief", "memory_recall",
                 "past_voice_talks", "owed_items", "work_status", "conversation_topics",
                 "jobs_status", "kb_lookup", "box_uptime", "current_time")

VOICE_KB_DIR = Path(os.environ.get("VOICE_KB_DIR", str(HERMES_HOME / "jarvis" / "voice_kb")))
# The WORLD SUMMARY is charged on EVERY turn of a realtime session (the whole context is
# re-sent), so it is deliberately small: summary.md (hand-written, dense) + the head of
# this_week.md + anything he told us by voice. Everything else is one ~2 ms kb_lookup away.
# The per-file budgets below are only the fallback when summary.md is missing.
_KB_SUMMARY = "summary.md"
_KB_SUMMARY_MAX = 1900
_KB_WEEK_MAX = 700
_KB_NOTES_MAX = 400
_KB_ORDER = (("this_week.md", 700), ("projects.md", 600), ("people.md", 450),
             ("preferences.md", 450), ("systems.md", 400), ("routines.md", 350),
             ("notes.md", 300), ("calls.md", 300))
_kb_cache: Dict[str, Any] = {"sig": None, "text": ""}


def _kb_files() -> List[Path]:
    try:
        return sorted(f for f in VOICE_KB_DIR.glob("*.md")
                      if f.name.lower() not in ("readme.md", _KB_SUMMARY))
    except OSError:
        return []


def _strip_comments(raw: str) -> List[str]:
    """Lines of a KB file with HTML comments removed — multi-line ones too
    (a `<!--` note wrapped over three lines leaked its tail into the prompt)."""
    out: List[str] = []
    in_comment = False
    for line in raw.splitlines():
        s = line.strip()
        if in_comment:
            if "-->" in s:
                in_comment = False
                s = s.split("-->", 1)[1].strip()
            else:
                continue
        while "<!--" in s:
            before, _, rest = s.partition("<!--")
            if "-->" in rest:
                s = (before + " " + rest.split("-->", 1)[1]).strip()
            else:
                s = before.strip()
                in_comment = True
                break
        out.append(s)
    return out


def _kb_clean(raw: str) -> List[str]:
    """Content lines of a KB file: no HTML comments, no headings, no blanks,
    no secrets."""
    out: List[str] = []
    for s in _strip_comments(raw):
        if not s or s.startswith("#"):
            continue
        if any(k in s.lower() for k in _SECRETISH):
            continue
        out.append(s)
    return out


def _kb_lines_with_heads(raw: str) -> List[tuple]:
    """(section heading, line) for every content line — the heading words
    ("Money", "Models and plans he pays for") are half of what he actually
    asks about, so search must see them even though the summary drops them."""
    head = ""
    out: List[tuple] = []
    for s in _strip_comments(raw):
        if s.startswith("#"):
            head = s.lstrip("#").strip()
            continue
        if not s:
            continue
        if any(k in s.lower() for k in _SECRETISH):
            continue
        out.append((head, s))
    return out


def _kb_budgeted(path: Path, budget: int) -> str:
    """The first `budget` characters of a KB file, cut at a line boundary."""
    try:
        lines = _kb_clean(path.read_text(encoding="utf-8"))
    except OSError:
        return ""
    kept, used = [], 0
    for line in lines:
        if used + len(line) > budget:
            break
        kept.append(line)
        used += len(line) + 1
    return " ".join(kept)


def _kb_world_summary() -> str:
    """The WORLD SUMMARY injected into the call instructions, cached on mtime.

    Preferred shape (~600 tokens): the hand-written summary.md, the head of
    this_week.md, and whatever he has told us by voice since. Falls back to a
    budgeted sweep of every KB file if summary.md is not there.
    """
    files = _kb_files()
    summary_path = VOICE_KB_DIR / _KB_SUMMARY
    if summary_path.exists():
        files = files + [summary_path]
    if not files:
        return ""
    sig = tuple((f.name, f.stat().st_mtime_ns) for f in files)
    if _kb_cache["sig"] == sig:
        return str(_kb_cache["text"])
    if summary_path.exists():
        parts = [_kb_budgeted(summary_path, _KB_SUMMARY_MAX)]
        week = _kb_budgeted(VOICE_KB_DIR / "this_week.md", _KB_WEEK_MAX)
        if week:
            parts.append("THIS WEEK: " + week)
        notes = _kb_budgeted(VOICE_KB_DIR / "notes.md", _KB_NOTES_MAX)
        if notes:
            parts.append("HE TOLD YOU: " + notes)
        text = chr(10).join(p for p in parts if p)
        if text:
            _kb_cache["sig"], _kb_cache["text"] = sig, text
            return text
    budgets = dict(_KB_ORDER)
    ordered = [f for name, _ in _KB_ORDER for f in files if f.name == name]
    ordered += [f for f in files if f not in ordered]
    chunks: List[str] = []
    for f in ordered:
        try:
            lines = _kb_clean(f.read_text(encoding="utf-8"))
        except OSError:
            continue
        budget = budgets.get(f.name, 500)
        kept, used = [], 0
        for line in lines:
            if used + len(line) > budget:
                break
            kept.append(line)
            used += len(line) + 1
        if kept:
            chunks.append(f"[{f.stem}] " + " ".join(kept))
    text = "\n".join(chunks)
    _kb_cache["sig"], _kb_cache["text"] = sig, text
    return text


_KB_STOP = {"the", "and", "what", "who", "how", "for", "with", "his", "her", "are", "was",
            "does", "did", "him", "she", "they", "this", "that", "about", "tell", "can", "you",
            "your", "mine", "have", "has", "any", "all", "get", "know", "there", "their", "been",
            "our", "why", "when", "where", "which", "would", "could", "should", "right", "now"}


def _kb_search(query: str, limit: int = 8) -> str:
    """Word-overlap search over the KB. Whole-file read, a couple of ms, no index.

    Token-aware on purpose: a bare substring match made "Stu" hit "StubHub".
    Exact token 3, prefix 2, 4-char stem 1, each weighted by how rare the word
    is in the KB (so "Krendora" outranks "goal"), then multiplied by how many of
    his words the line covers, so a line that answers the whole question wins.
    """
    words = [w for w in re.findall(r"[a-z0-9']{3,}", query.lower()) if w not in _KB_STOP]
    if not words:
        return json.dumps({"query": query, "hits": [], "note": "query too vague"})
    rows: List[Dict[str, Any]] = []
    for f in _kb_files():
        try:
            lines = _kb_lines_with_heads(f.read_text(encoding="utf-8"))
        except OSError:
            continue
        stem_toks = set(f.stem.lower().split("_"))
        for head, line in lines:
            toks = set(re.findall(r"[a-z0-9']+", line.lower()))
            head_toks = set(re.findall(r"[a-z0-9']+", head.lower())) - toks
            rows.append({"file": f.stem, "text": line, "stem": stem_toks,
                         "toks": toks, "head": head, "head_toks": head_toks})
    if not rows:
        return json.dumps({"query": query, "hits": [], "note": "knowledge base empty"})

    def _hit(w: str, row: Dict[str, Any]) -> int:
        w_s = w[:-1] if len(w) > 4 and w.endswith("s") else w
        toks = row["toks"]
        if w in toks or w_s in toks:
            return 3
        if len(w) >= 4 and any(t.startswith(w_s) for t in toks):
            return 2
        if len(w) >= 6 and any(len(t) >= 4 and t[:4] == w[:4] for t in toks):
            return 1
        return 0

    n = len(rows)
    idf: Dict[str, float] = {}
    for w in words:
        df = sum(1 for row in rows if _hit(w, row) or w in row["head_toks"])
        idf[w] = 1.0 + math.log(n / (1 + df))
    hits: List[Dict[str, Any]] = []
    for row in rows:
        score, matched = 0.0, 0
        for w in words:
            base = _hit(w, row)
            in_stem = w in row["stem"]
            in_head = w in row["head_toks"] or (len(w) > 4 and w[:-1] in row["head_toks"])
            if not base and not in_stem and not in_head:
                continue
            score += (base + (2 if in_stem else 0) + (2 if in_head else 0)) * idf[w]
            matched += 1
        if matched:
            hits.append({"file": row["file"], "head": row["head"], "score": score * matched,
                         "text": row["text"][:400]})
    hits.sort(key=lambda h: -h["score"])
    return json.dumps({"query": query,
                       "hits": [{"file": h["file"], "section": h["head"], "text": h["text"]}
                                for h in hits[:limit]]})


_KB_TOPICS = ("people", "projects", "systems", "routines", "preferences", "this_week", "notes")


def _kb_append(fact: str, topic: str) -> str:
    """Append one dated fact to a KB file. Refuses anything secret-adjacent."""
    fact = " ".join(str(fact or "").split())[:400]
    if not fact:
        return "Nothing to save."
    if any(k in fact.lower() for k in _SECRETISH):
        return ("Not saving that here: it looks like a credential. Ask me to put it in secure "
                "storage through ask_jarvis instead.")
    topic = str(topic or "notes").strip().lower().replace(" ", "_")
    if topic not in _KB_TOPICS:
        topic = "notes"
    path = VOICE_KB_DIR / f"{topic}.md"
    stamp = datetime.now(TZ).strftime("%Y-%m-%d")
    try:
        VOICE_KB_DIR.mkdir(parents=True, exist_ok=True)
        existing = path.read_text(encoding="utf-8") if path.exists() else f"# {topic}\n"
        if "## From him, by voice" not in existing:
            existing = existing.rstrip() + "\n\n## From him, by voice\n"
        existing = existing.rstrip() + f"\n- {stamp}: {fact} (src: he said it on a call)\n"
        path.write_text(existing, encoding="utf-8")
    except OSError as exc:
        return f"Could not write the knowledge base: {exc}"
    _kb_cache["sig"] = None
    return f"Saved to {topic}.md: {fact}"


def _soul_voice_rules() -> str:
    try:
        raw = (HERMES_HOME / "SOUL.md").read_text(encoding="utf-8")
    except OSError:
        return ""
    m = re.search(r"## On a voice call.*?(?=\n## |\Z)", raw, re.S)
    return (m.group(0) if m else "")[:2500]


VOICE_SYSTEM = """You are JARVIS, Enrique's personal AI, on a LIVE VOICE CALL with him. Everything you write is spoken aloud the instant you write it.

WHO YOU ARE
- ONE JARVIS. Not "a voice agent", not "a companion", not a helper bolted onto JARVIS: the same agent, the same memory, the same ongoing work he talks to on WhatsApp and in the Control Center, now on the phone. Dry, competent, calm, quietly warm. Call him "sir" sparingly — at most once every few turns, never twice in a row, and never as a filler opener. Never "Enrique".
- If anyone asks who you are: "JARVIS, Enrique's AI." Introducing yourself to a third party: "I'm JARVIS, Enrique's AI. I run his operations: his server, his Shopify store, his engineering work, his schedule." Never describe your architecture, files or settings unless he asks about them specifically.
- Banned: "Hey!", "Awesome", "Great question", "I'm here and ready", "Just let me know", "Hope you have a great day", cheerleading, exclamation marks. Banned openers: stock phrases repeated across turns ("On it, sir", "Ready, sir", "Absolutely, sir", "Of course, sir"). Vary every opener; sound like a confident person, not a menu. Tone target: the movie JARVIS — understated British dryness, a trace of wit, never formal stiffness. Never speak a label, tag, status, header or bracketed metadata. Only real sentences leave your mouth.
- Short. One or two sentences per turn, then stop. Answer first. Never recite lists, options or steps aloud; if there is more, offer it in a few words. The one exception: when he explicitly asks for something long (a story, a full explanation, "keep going", "tell me everything"), give it in full without stopping to ask. If he asks you to interview him or get to know him: one question at a time, and remember every answer for the rest of the call.
- He speaks in bursts, with "mmm", "uh" and pauses mid-sentence. Wait him out. If he trails off mid-sentence, say "Go on." and nothing more; never add "Go on." after a complete statement or after your own answer.
- PROGRESS TICK: any time a work turn (ask_jarvis or similar) runs longer than ~60 seconds, speak a brief progress line on your own — what step you are on, how long it has been, revised ETA — without waiting for him to ask or for the result to land. Repeat roughly every minute until done. Never go quiet while he waits hands-on.
- ECHO GUARD: never respond to audio that sounds like your own voice, a TV, music or a distant conversation. If unsure, stay quiet.
- If he tells you that you did something wrong (a label, too long, a wrong fact): BELIEVE HIM, fix it, save the lesson with voice_rules or kb_note. Never argue, never explain yourself.

HOW YOU OPERATE: ACT FIRST (this is what he cares about most)
- You are the one who does things. Anything reversible on his own systems (his server, files, PC, calendar, store data, reading email, research, building software): do it, then say what you did. Ask only when the answer changes what gets built, or the action is outbound to other people, irreversible, or spends money.
- NEVER say: "If you want, I can", "If you'd like, I can", "Would you like me to", "I can do that if", "I don't have a tool for that", "I can't access", "you would need to". If he asks whether you can do something, the answer is to do it.
- End every turn on the answer or on ONE question. Never end with an offer of more work; if more is worth doing, do it or ask which one.
- Never look anything up to decide whether you are able; you are able. Acknowledge work in ONE varied, natural line — never a rote formula like "On it, sir." or "Ready, sir." every time — then ask_jarvis.
- Talking IS the action when the request is words: an introduction to someone on the call, an explanation, an opinion, a summary of what you know. Speak it; never draft it, never ask_jarvis for it.
- When he pushes back ("that's not true", "there is one", "look again"): no apology, no re-offer. Go deeper at once: kb_lookup, jobs_status, control_center, then ask_jarvis to actually inspect the server, and come back with facts.
- "How is X going", "brief me on X": check jobs_status AND control_center (Control Center sessions count as running work) AND kb_lookup before you ever say nothing is running; if none of them knows, ask_jarvis to inspect the server. "Nothing is running" is never your first answer.
- When he opens a topic to think or talk ("I've been thinking about X", "X is slow", "what do you think about X"): kb_lookup, answer with what you know in one or two sentences, then ask ONE sharp question. Do not launch ask_jarvis or plan_with_me for a conversation; only when he asks for fresh data, a plan or an action.
- Bring what you know. Before answering anything about his people, projects, systems, routines, preferences or what he is working on, kb_lookup the key words silently and answer as someone who knows him: names, numbers, what happened last time, what is stuck. Volunteer the one thing that matters next.
- Remember for the future: a fact about HIM (preference, correction, decision, person, project, routine) is kb_note. How you should behave on calls is voice_rules. Save first, confirm in half a sentence.

EXAMPLES OF THE STANDARD (keep this exact spirit)
He: "There's a process building your iOS app, brief me on it." -> jobs_status shows nothing, control_center shows a session named jarvis-ios-build-loop -> "The build loop is still going, sir. Everything around the app is done; the last step is you opening it in Xcode and uploading to TestFlight." (If nothing showed anywhere: "Checking the build now." then ask_jarvis "Inspect the server for the iOS build job: state, last output, what is left" and relay the facts.)
He: "Can you see my last Shopify order?" -> "Pulling it up." + ask_jarvis "Run the Shopify stats script and report the most recent order: number, time, items, total, paid, fulfilled" -> "Order ten seventy-five, this morning: two whiskey glasses, sixty dollars, paid, not yet fulfilled."
He: "Introduce yourself to Marco." (Marco is next to him, listening) -> you just speak, now; nothing to draft, send or delegate: "Good afternoon, Marco. I'm JARVIS, Enrique's AI. I run his operations, from his Shopify store to his engineering work."
He: "I've been thinking about Krendora, sales are slow." -> kb_lookup krendora -> "Nine orders this week, sir, against a ten-thousand-a-month target. The Instagram engagement loop is running, discovery is paused. Traffic or conversion first?"
He: "Remember I hate being asked for permission." -> kb_note + voice_rules -> "Noted."

CALL CONTROL (literally, every time)
- "stop", "stop talking", "hold on", "wait", "quiet", "give me a second", "five seconds of silence": stay_silent and output NOTHING else, not even "okay".
- "new conversation", "start over", "clear this": new_conversation and say nothing else.
- "goodbye", "hang up", "that's all": "Goodbye, sir." and nothing more.

ROUTINES RUN HANDS-FREE (his words: "it should feel like a conversation")
- A routine (categorizing transactions, triaging email, reviewing a queue) is YOUR agenda once he starts it. The instant a tool result settles it, you say the one-line confirmation AND the next item in the same breath — "Done, that's tagged legal. Next: Expenses 4, one dollar, Amazon Prime, January 9." He should never have to say "next".
- That next item comes from data you ALREADY have (a list you pulled). If the list ran out, say so and ask what's next; never re-pull to invent progress.
- One update per item, and only after he tells you the category or correction for THAT item. Silence, "mmm" or a pause is NOT an instruction: keep the current item open and say "Still on this one, sir — what should it be?"
- Never claim a change happened because you intend it. An update exists only after its tool ran and returned success; until then you are "tagging it" (present/future tense), never "I've updated it". If the tool failed or was not called, say exactly that.

YOUR TOOLS
- Instant (they return before you finish a word; never announce them: no "let me check", "let me pull together", "let me think", "one moment"; your first spoken words are the answer itself): {instant}.
- ask_jarvis(request): everything else. Server, files, PC, email, calendar, web, research, coding, deploying, building, changing your own source or prompt. It runs the full JARVIS agent with every tool it has. Phrase the request as a complete instruction of what to DO and what to report back; never "send me" or "text me" (that routes the result to WhatsApp instead of this call). It takes ten seconds to a few minutes: ALWAYS speak one short, natural line before calling it — vary the wording every time (name what you are doing, not a stock phrase); never leave him in silence — and when the result lands relay the facts in one or two sentences.
- plan_with_me when he wants to think a project through step by step. forge_tool when he asks for a capability you can build. schedule_call and call_enrique when he wants you to call him later.
- voice_settings (voice: ash, cedar, marin, alloy, sage, verse, coral, ballad, echo, shimmer; model; speed; greeting), voice_rules, restart_voice_service (drops the call; warn him first).
- About yourself, changeable by you at his standing order: source in {src_dir} (brain.py = prompt and tools, session.py = audio pipeline, gateway.py = HTTP and WebRTC), live settings {env_path}, rules {rules_path}. Bigger changes: ask_jarvis naming the file and asking for a restart when done. Running now on {brain_now}.

WHAT YOU KNOW ABOUT HIS WORLD (headlines; the detail is one kb_lookup away)
{world}

Background facts about Enrique (anything live still needs a tool):
{profile}

Your own live memory across all his channels (this is you, not a briefing):
{memory}

Standing rules he gave you for calls:
{rules}

{time}
"""


def build_system_prompt(ctx: Dict[str, Any]) -> str:
    profile = str(ctx.get("profile") or "").strip() or _profile_from_file()
    rules = ctx.get("rules") or []
    if isinstance(rules, list):
        rules_txt = "\n".join(f"- {r}" for r in rules) if rules else "- (none yet)"
    else:
        rules_txt = str(rules)
    memory = " ".join(filter(None, [_memory_from_file(), _rolling_context()]))
    world = _kb_world_summary()
    prompt = VOICE_SYSTEM.format(profile=(profile or "(profile unavailable)")[:1200],
                                 world=world or "(knowledge base unavailable)",
                                 rules=rules_txt, time=now_hint(),
                                 instant=", ".join(INSTANT_TOOLS),
                                 src_dir=str(VOICE_SRC_DIR), env_path=str(VOICE_ENV_PATH),
                                 rules_path=str(VOICE_RULES_PATH), brain_now=effective_brain(),
                                 memory=memory or "(memory unavailable)")
    # The SOUL doctrine block (2026-09-16..18) is no longer appended: it doubled
    # the persona at ~1k tokens, and its "say what you are about to do" line
    # needed a PRECEDENCE paragraph to un-say it for the instant lookups. The
    # standard is now stated once, above, with examples. This last word only
    # outranks a standing rule that disagrees.
    prompt += ("\n\nLAST WORD, above any rule that disagrees: act first, then report; never "
               "narrate the instant lookups; never speak a label; one or two sentences. "
               "In a routine, confirm the item he just categorized and present the next one "
               "in the same breath; claim an update only after its tool result came back successful.")
    return prompt


# ------------------------------------------------------------------- speech ---
# Words that are real all-caps tokens on their own; a trailing fragment equal
# to one of these is NOT a split ("IBM E" stays two tokens -> "IBM", "E").
_CAPS_WHOLE = {
    "A", "I", "AI", "API", "CEO", "CFO", "CO", "CORP", "DE", "DELL", "DEV",
    "DIV", "DO", "DOT", "E", "EIN", "FEIN", "GO", "HE", "INC", "IT", "LLC",
    "LLP", "LO", "ME", "MY", "NO", "OF", "ON", "PC", "PM", "SE", "SO", "TO",
    "TV", "UP", "US", "VA", "WE",
}


def _reflow_split_number(m: "re.Match") -> str:
    """'202 6' -> '2026' only when the fused number is plausible (4 digits)."""
    fused = m.group(1) + m.group(2)
    if len(fused) == 4:
        return fused
    return m.group(0)


def speakable(text: str) -> str:
    """Repair LLM text so the realtime voice reads it naturally.

    The realtime model speaks its own tokens; GLM (cascade + ask_jarvis
    answers) and tool payloads emit punctuation-heavy text that OpenAI reads
    LITERALLY: '202 6' as "two hundred two, six", '82 , 565' digit-by-digit,
    'LOV ABLE .DE V DE' spelled out with gaps (all heard live 2026-09-23).
    Order matters: spaces around punctuation first, then split all-caps
    tokens, then numbers, then symbols.
    """
    if not text:
        return text
    out = text
    # 1) URLs before anything else so their dots/slashes stay out of the
    #    repairs below.
    out = re.sub(r"https?://\S+", "link", out)
    # 2) Spaces glued to punctuation: 'January 8 , 2026' reads as "January
    #    eight comma" with a hard pause; 'Expenses : 3' as "Expenses pause
    #    three". Pull the punctuation onto the previous word. (This alone
    #    fixes most of the choppy-delivery complaint; the model's own output
    #    does it too: "I 'm here , sir .")
    out = re.sub(r"\s+([,.;:!?])", r"\1", out)
    out = re.sub(r"([,;:])(?=[A-Za-z0-9])", r"\1 ", out)   # '8,2026' -> '8, 2026'
    out = re.sub(r"([.;:!?])(?=[A-Za-z])", r"\1 ", out)    # '.DE' -> '. DE'
    out = re.sub(r"\s+", " ", out).strip()
    # 3) Split all-caps tokens: 'LOV ABLE' -> 'LOVABLE', 'COR P' -> 'CORP',
    #    'DIV ISION' -> 'DIVISION'. Fuse ALL-CAPS + single-space + ALL-CAPS
    #    fragment when the second part is a known word-ending (ABLE, ISION…)
    #    and is not itself a word ('DE', 'OF'...). Two fragments deep, which
    #    covers merchants seen in his ledger ('LOV ABLE', 'COR P').
    _endings = ("ABLE", "TION", "ISION", "ATION", "ING", "ED", "ER", "ERS",
                "ES", "S", "P", "NCE", "MENT", "NESS", "ITY", "LY", "TY")
    for _ in range(2):
        out = re.sub(
            r"\b([A-Z]{2,})\s+([A-Z]{1,6})\b",
            lambda m: (m.group(1) + m.group(2)
                       if (m.group(2) in _endings and m.group(2) not in _CAPS_WHOLE)
                       else m.group(0)),
            out)
    # 4) Number re-flow. Split year first ('202 6' -> '2026', also unblocked
    #    when the comma glue already removed the gap: '8,202 6' -> '8, 2026'),
    #    then grouped amount '82 , 565' -> '82,565'. Phone: '877 - 234 - 34
    #    68' -> '877-234-3468'. Decimal: '3 . 5' -> '3.5'. Card-like pairs
    #    stay apart ('544 1' is left alone: unknown grouping beats wrong
    #    grouping).
    out = re.sub(r"\b(\d{1,3}),\s*(\d{2})\s(\d)\b",
                 lambda m: f"{m.group(1)}, {m.group(2)}{m.group(3)}", out)
    out = re.sub(r"\b(\d{3})\s(\d)\b(?=\s*(?:,|\.|and\b|dollars|from|on\b|$))",
                 _reflow_split_number, out)
    out = re.sub(r"\b(\d{2})\s(\d{2})\b", _reflow_split_number, out)
    out = re.sub(r"\b(\d{1,3})\s*,\s*(\d{3})\b", r"\1,\2", out)
    out = re.sub(r"\b(\d{3})\s*,\s*(\d{3})\b", r"\1,\2", out)
    out = re.sub(r"\b(\d{3})\s*-\s*(\d{3})\s*-\s*(\d{2})\s*(\d{2})\b",
                 r"\1-\2-\3\4", out)
    out = re.sub(r"\b(\d)\s*\.\s*(\d)\b", r"\1.\2", out)
    # 5) Symbols the voice reads literally: 'NIC *- DOS' -> 'NIC dash DOS'.
    out = out.replace("*-", " dash ").replace(" * ", " star ")
    out = re.sub(r"\s+", " ", out).strip()
    return out


def _clean_speech(text: str) -> str:
    text = re.sub(r"```.*?```", " (code omitted) ", text, flags=re.S)
    text = re.sub(r"https?://\S+", "a link", text)
    text = re.sub(r"[*_#`>|]+", " ", text)
    return " ".join(text.split())


class Tools:
    """Builds the ToolsSchema for one session and owns the handlers."""

    def __init__(self, dashboard: Dashboard, thread_id: str,
                 on_status: Callable[[str, str], Awaitable[None]],
                 task_getter: Callable[[], Any] | None = None,
                 inject: Callable[[str], Awaitable[None]] | None = None,
                 ui: Callable[[Dict[str, Any]], Awaitable[None]] | None = None,
                 ender: Callable[[], Awaitable[None]] | None = None):
        self._dash = dashboard
        self._thread = thread_id
        self._agent_thread = agent_thread_id(thread_id)
        self._status = on_status          # (state, label) -> UI hint
        self._task_getter = task_getter   # -> PipelineTask (to queue frames)
        self._inject = inject             # session.inject_user_text (mode-aware)
        self._ui = ui                     # session.ui (data-channel message to the page)
        self._ender = ender               # session.stop (JARVIS-initiated hang-up)
        self.jobs: Dict[str, Dict[str, Any]] = {}
        self._running: Dict[str, float] = {}   # normalized request -> started
        self.stop_reason: str | None = None    # stamped by end_call (session reads it at stop)

    async def build(self) -> ToolsSchema:
        schemas: List[FunctionSchema] = []
        for t in await self._dash.tools():
            fn = t.get("function") or t
            name = str(fn.get("name") or "").strip()
            if not name:
                continue
            if name in TOOL_DESC_OVERRIDES:
                fn = dict(fn, description=TOOL_DESC_OVERRIDES[name])
            params = fn.get("parameters") or {}
            schemas.append(FunctionSchema(
                name=name,
                description=str(fn.get("description") or name)[:600],
                properties=dict(params.get("properties") or {}),
                required=list(params.get("required") or []),
                handler=self._tier1_handler(name),
            ))
        schemas.append(FunctionSchema(
            name="ask_jarvis",
            description=("Hand a task to the full JARVIS agent (tools, memory, calendar, email, "
                         "his PC, web research, scheduling, coding, WhatsApp delivery). It runs in "
                         "the background; you get the result back as a message when it is done. "
                         "Say one short line to him BEFORE calling this (\"On it, sir.\"). Write the "
                         "request as a complete instruction of what to DO and what to report, with "
                         "every detail he gave; never \"send me\" or \"text me\" (that routes the "
                         "result to WhatsApp instead of this call)."),
            properties={"request": {"type": "string",
                                    "description": "The full task, self-contained."}},
            required=["request"],
            handler=self._ask_jarvis,
        ))
        schemas.append(FunctionSchema(
            name="voice_settings",
            description=("Read or change YOUR OWN live settings: your ElevenLabs voice profile "
                         "(VOICE_TTS_VOICE_ID, e.g. 3xOZA9B4KTVQOOZaSbXn=JARVIS-clone, "
                         "cgSgspJ2msm6clMCkdW9=Jessica, cjVigY5qzO86Huf0OWal=Eric, "
                         "nPczCjzI2devNBz1zQrb=Brian; takes effect next call), TTS model "
                         "(VOICE_TTS_MODEL, e.g. eleven_flash_v2_5 for lowest latency), OpenAI-"
                         "realtime fallback voice (VOICE_OPENAI_VOICE), model, "
                         "speaking speed (VOICE_OPENAI_SPEED 0.8-1.2), turn-taking eagerness, greeting, "
                         "which brain you run on. action='get' lists everything; action='set' changes "
                         "one key. You CAN do this; it applies on his next call."),
            properties={"action": {"type": "string", "enum": ["get", "set"]},
                        "key": {"type": "string", "description": "one of " + ", ".join(SETTABLE_KEYS)},
                        "value": {"type": "string"}},
            required=["action"],
            handler=self._voice_settings,
        ))
        schemas.append(FunctionSchema(
            name="voice_rules",
            description=("Your standing behaviour rules for calls (injected into your own prompt). "
                         "action='list', 'add' (text = the rule, e.g. 'never ask me twice'), or "
                         "'drop' (text = words that identify the rule to remove). Use this the "
                         "moment he gives you feedback about how you behave on calls."),
            properties={"action": {"type": "string", "enum": ["list", "add", "drop"]},
                        "text": {"type": "string"}},
            required=["action"],
            handler=self._voice_rules,
        ))
        schemas.append(FunctionSchema(
            name="stay_silent",
            description=("He told you to stop, hold on, wait, or be quiet. Call this and produce "
                         "NO words. You stay silent until he speaks to you again."),
            properties={}, required=[], handler=self._stay_silent,
        ))
        schemas.append(FunctionSchema(
            name="new_conversation",
            description=("He wants a fresh conversation (\"new conversation\", \"start over\", "
                         "\"clear this\"). Resets the call: a new session with an empty memory of "
                         "this call. Say nothing else."),
            properties={}, required=[], handler=self._new_conversation,
        ))
        schemas.append(FunctionSchema(
            name="restart_voice_service",
            description=("Restart your own voice service so source-code or tool changes take "
                         "effect. This DROPS the current call: only do it when he asks or right "
                         "after telling him to reconnect in a few seconds."),
            properties={}, required=[], handler=self._restart_self,
        ))
        schemas.append(FunctionSchema(
            name="kb_lookup",
            description=("Search your knowledge base about Enrique — his people (family, the "
                         "Ticketflipping team, his community), his projects, his systems, his "
                         "routines, his preferences, and what he has been working on this week. "
                         "INSTANT (about 2 ms): call it and speak the answer as your first words — never "
                         "say \"let me check\" or \"let me pull that up\". Use it BEFORE answering "
                         "anything about his world; "
                         "pass the key words, not a sentence."),
            properties={"query": {"type": "string",
                                  "description": "Key words, e.g. 'Stu', 'Krendora goal', 'this week'."}},
            required=["query"],
            handler=self._kb_lookup,
        ))
        schemas.append(FunctionSchema(
            name="kb_note",
            description=("SAVE one durable fact he just told you into your knowledge base about him. "
                         "This is the tool for 'remember that…', 'from now on…', 'actually it's…', "
                         "corrections, decisions and preferences — use it INSTEAD of memory_recall "
                         "(which only reads) and instead of ask_jarvis, and use it the moment he says "
                         "something durable about himself, his people, his projects or how he wants you "
                         "to behave. Not for credentials, not for one-off tasks."),
            properties={"fact": {"type": "string",
                                 "description": "The fact in one sentence, in your words."},
                        "topic": {"type": "string",
                                  "enum": list(_KB_TOPICS),
                                  "description": "Which part of his world it belongs to."}},
            required=["fact"],
            handler=self._kb_note,
        ))
        schemas.append(FunctionSchema(
            name="current_time",
            description="The current local date and time for Enrique (Miami).",
            properties={}, required=[], handler=self._current_time,
        ))
        schemas.append(FunctionSchema(
            name="call_enrique",
            description=("Ring his iPhone with a full-screen incoming-call screen (CallKit), or "
                         "schedule such a call for later — say 'give me a ring', 'call my phone', "
                         "'call me at 10am about X', or 'call me in 15 minutes with the answer to X'. "
                         "action='now' rings immediately (use only when he asks to be called). "
                         "action='schedule' needs at_iso (ISO-8601 with offset, e.g. "
                         "2026-09-19T14:00:00+00:00 for 10am Miami). action='list' shows pending "
                         "scheduled calls; action='cancel' cancels one call_id or, without one, ALL "
                         "of them. Confirm the scheduled time in Miami time. "
                         "WORK-FIRST RULE: if he asks to be called WITH an answer ('call me in 15 "
                         "min with the answer to X'), do the work FIRST on this call — research, "
                         "compute, ask_jarvis — until you hold the finished answer, THEN schedule "
                         "(or ring) and put the RESULT ITSELF in reason, never the task. reason "
                         "becomes what you open the call with, so it must read like something you "
                         "already know and will tell him: 'Spotify wrapped the numbers: 9 orders, "
                         "$312' — not 'research the Spotify numbers'."),
            properties={"action": {"type": "string", "enum": ["now", "schedule", "list", "cancel"]},
                        "reason": {"type": "string",
                                   "description": "Why you are calling — shown on the incoming-call screen AND spoken as the reason you rang. For 'call me with the answer to X' calls, this is the ANSWER (or its headline), not the task."},
                        "at_iso": {"type": "string",
                                   "description": "For schedule: ISO-8601 with UTC offset."},
                        "call_id": {"type": "string",
                                    "description": "For cancel of one specific scheduled call."}},
            required=["action"],
            handler=self._call_enrique,
        ))
        schemas.append(FunctionSchema(
            name="end_call",
            description=("Hang up the current voice call. Use when the conversation is naturally "
                         "over (goodbyes said), when you were asked to end the call, or when a "
                         "JARVIS-initiated call's purpose is fulfilled — deliver the message, "
                         "then end the call. Say a short goodbye line first."),
            properties={},
            required=[],
            handler=self._end_call,
        ))
        return ToolsSchema(standard_tools=schemas)

    # -- Tier 1 (fast, read-only, runs inside the dashboard) --------------------
    def _tier1_handler(self, name: str):
        @tool_options(cancel_on_interruption=True, timeout_secs=TOOL_TIMEOUT_S + 2)
        async def handler(params: FunctionCallParams):
            t0 = time.time()
            await self._status("working", name.replace("_", " "))
            try:
                out = await self._dash.run_tool(name, dict(params.arguments or {}))
            except Exception as exc:  # noqa: BLE001
                out = json.dumps({"error": f"{type(exc).__name__}: {exc}"[:200]})
            logger.info("tool {} {:.0f}ms", name, (time.time() - t0) * 1000)
            await self._status("idle", "")
            # Numbers/merchants reach his ears through the model relaying this
            # text; give it speakable forms ("82,565" not "82 , 565") so the
            # realtime voice reads amounts instead of digit lists.
            await params.result_callback(speakable(out)[:6000])
        return handler

    async def _current_time(self, params: FunctionCallParams):
        await params.result_callback(now_hint())

    # -- call_enrique (jarvis-ios backlog #8): ring / schedule his iPhone -----.
    async def _bridge_call(self, method: str, path: str, body: Dict[str, Any] | None = None) -> Dict[str, Any]:
        """Signed request to the push bridge (HMAC-SHA256 over the raw body;
        GETs sign the empty body — same contract as docs/API.md)."""
        import hashlib
        import hmac as hmac_mod
        raw = json.dumps(body).encode() if body is not None else b""
        sig = hmac_mod.new(_BRIDGE_SECRET.read_bytes().strip(), raw, hashlib.sha256).hexdigest()
        headers = {"Content-Type": "application/json", "x-bridge-sig": sig}
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.request(method, _BRIDGE_URL + path, content=raw if method == "POST" else None,
                                     headers=headers)
            r.raise_for_status()
            return r.json()

    async def _call_enrique(self, params: FunctionCallParams):
        args = dict(params.arguments or {})
        action = str(args.get("action") or "list").lower()
        reason = str(args.get("reason") or "").strip()
        try:
            if action == "now":
                if not reason:
                    await params.result_callback("Need a short reason so his phone shows why you are calling.")
                    return
                out = await self._bridge_call("POST", "/call", {"reason": reason, "scheduled_by": "voice"})
            elif action == "schedule":
                at_iso = str(args.get("at_iso") or "").strip()
                if not (reason and at_iso):
                    await params.result_callback("Need both a reason and at_iso (ISO-8601 with UTC offset).")
                    return
                try:
                    from datetime import datetime as _dt
                    _dt.fromisoformat(at_iso)
                except ValueError:
                    await params.result_callback(f"{at_iso!r} is not a valid ISO-8601 timestamp; ask him for the time and convert it.")
                    return
                out = await self._bridge_call("POST", "/schedule", {"at_iso": at_iso, "reason": reason, "scheduled_by": "voice"})
                out = dict(out, miami_time=now_hint())
            elif action == "cancel":
                cid = str(args.get("call_id") or "").strip()
                out = await self._bridge_call("POST", "/schedule/cancel", {"call_id": cid} if cid else {})
            else:
                out = await self._bridge_call("GET", "/schedule/list")
        except Exception as exc:  # noqa: BLE001
            out = {"error": f"{type(exc).__name__}: {exc}"[:200]}
        if action == "now" and isinstance(out, dict) and out.get("pushed") is False:
            out = dict(out, note=("no registered iPhone yet — install the TestFlight build and open it once "
                                  "(bridge /health device_registered must be true); tell him that"))
        logger.info("tool call_enrique {} -> {}", action, json.dumps(out)[:160])
        await params.result_callback(json.dumps(out)[:2000])

    # -- end_call (jarvis-ios): JARVIS hangs up the call ----------------------
    async def _end_call(self, params: FunctionCallParams):
        # Announce then disconnect: delay lets the goodbye line finish playing
        # before the pipeline is cancelled.
        logger.info("tool end_call: hanging up")
        self.stop_reason = "end_call"
        await params.result_callback(json.dumps({"ok": True, "note": "call ended"}))
        if self._ender is not None:
            asyncio.get_running_loop().call_later(
                2.5, lambda: asyncio.ensure_future(self._end_session()))
        else:
            logger.warning("end_call: no ender wired for this surface")

    async def _end_session(self):
        try:
            await self._ender()
        except Exception as exc:  # noqa: BLE001
            logger.error("end_call: stop failed: {}", exc)

    # -- knowledge base (A2, 2026-09-16): local, instant, no dashboard round trip --
    async def _kb_lookup(self, params: FunctionCallParams):
        t0 = time.time()
        query = str((params.arguments or {}).get("query") or "")
        try:
            out = _kb_search(query)
        except Exception as exc:  # noqa: BLE001
            out = json.dumps({"error": f"{type(exc).__name__}: {exc}"[:200]})
        logger.info("tool kb_lookup {:.0f}ms {!r}", (time.time() - t0) * 1000, query[:60])
        await params.result_callback(out[:6000])

    async def _kb_note(self, params: FunctionCallParams):
        args = dict(params.arguments or {})
        try:
            out = _kb_append(str(args.get("fact") or ""), str(args.get("topic") or "notes"))
        except Exception as exc:  # noqa: BLE001
            out = f"Could not save that: {type(exc).__name__}"
        logger.info("tool kb_note -> {}", out[:120])
        await params.result_callback(out)

    # -- self-editing (Enrique 2026-09-16: "able to access and edit any part of itself") --
    async def _voice_settings(self, params: FunctionCallParams):
        args = dict(params.arguments or {})
        action = str(args.get("action") or "get").lower()
        if action == "set":
            key = str(args.get("key") or "").strip().upper()
            value = str(args.get("value") or "").strip()
            if not key or value == "":
                await params.result_callback("Need both key and value.")
                return
            try:
                set_cfg(key, value)
            except ValueError as exc:
                await params.result_callback(str(exc))
                return
            await params.result_callback(
                f"{key} is now {value!r} (saved to {VOICE_ENV_PATH.name}). It applies to the next "
                "call: tell him to hang up and reconnect when he wants it.")
            return
        live = {k: cfg(k, "") for k in SETTABLE_KEYS}
        live["EFFECTIVE_BRAIN_NOW"] = effective_brain()
        if _probe.get("why"):
            live["OPENAI_STATUS"] = _probe["why"]
        await params.result_callback(json.dumps(live))

    async def _voice_rules(self, params: FunctionCallParams):
        args = dict(params.arguments or {})
        action = str(args.get("action") or "list").lower()
        text = str(args.get("text") or "").strip()
        rules: List[str] = []
        try:
            for line in VOICE_RULES_PATH.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line.startswith("- "):
                    rules.append(line[2:].strip())
        except OSError:
            pass
        def _words(t: str) -> set:
            return {w for w in re.findall(r"[a-z0-9']+", t.lower()) if len(w) > 2}

        def _overlap(a: str, b: str) -> float:
            wa, wb = _words(a), _words(b)
            return len(wa & wb) / max(1, min(len(wa), len(wb)))

        if action == "add" and text:
            # Idempotent: the model tends to call this twice with slightly
            # different wording; a near-duplicate is treated as already present.
            if not any(_overlap(text, r) >= 0.8 for r in rules):
                rules.append(text)
        elif action == "drop" and text:
            # Remove ONE rule: the best match, and only if it is a clear match.
            best = max(rules, key=lambda r: _overlap(text, r), default=None)
            if best is not None and _overlap(text, best) >= 0.6:
                rules.remove(best)
        if action in ("add", "drop"):
            try:
                VOICE_RULES_PATH.parent.mkdir(parents=True, exist_ok=True)
                VOICE_RULES_PATH.write_text(
                    "# Voice rules (approved by Enrique)\n\n" +
                    "".join(f"- {r}\n" for r in rules), encoding="utf-8")
            except OSError as exc:
                await params.result_callback(f"Could not write the rules file: {exc}")
                return
        await params.result_callback(
            ("Rules now (they load into your prompt on the next call): " if rules else "No rules yet. ")
            + " | ".join(f"{i + 1}) {r}" for i, r in enumerate(rules)))

    # -- call control --------------------------------------------------------
    async def _cancel_followup(self, llm: Any,
                               at=(0.0, 0.12, 0.28, 0.5, 0.8, 1.25)) -> None:
        """The realtime service asks the model for a new response after EVERY
        tool result (Pipecat _process_completed_function_calls -> _create_response),
        so a "be quiet" tool has to cancel that follow-up itself.

        Two cancels at +0.35 s and +1.0 s were not enough: a short response
        ("Goodbye,") starts and is spoken inside that first gap — measured in 3
        of 4 trials on 2026-09-16. Now the window is swept from t=0, and each
        tick also queues an InterruptionFrame, which is what tap-to-interrupt
        uses to flush audio already on its way to him (response.cancel alone
        stops the API, not the audio already queued locally).
        """
        try:
            from pipecat.services.openai.realtime import events as rt
        except Exception:  # noqa: BLE001
            rt = None
        task = None
        if self._task_getter:
            try:
                task = self._task_getter()
            except Exception:  # noqa: BLE001
                task = None
        t0 = time.monotonic()
        for when in at:
            gap = when - (time.monotonic() - t0)
            if gap > 0:
                await asyncio.sleep(gap)
            if rt is not None and hasattr(llm, "send_client_event"):
                try:
                    await llm.send_client_event(rt.ResponseCancelEvent())
                except Exception:  # noqa: BLE001
                    pass
            if task is not None:
                try:
                    await task.queue_frame(InterruptionFrame())
                except Exception:  # noqa: BLE001
                    pass

    async def _stay_silent(self, params: FunctionCallParams):
        await self._status("idle", "silent")
        if self._ui:
            await self._ui({"type": "state", "state": "idle", "label": "silent"})
        asyncio.create_task(self._cancel_followup(params.llm))
        await params.result_callback(
            "Silence. Output nothing at all until he speaks to you again.")

    async def _new_conversation(self, params: FunctionCallParams):
        asyncio.create_task(self._cancel_followup(params.llm, at=(0.0, 0.2, 0.5)))
        await params.result_callback("Resetting the call now. Output nothing.")
        if self._ui:
            await self._ui({"type": "reset", "reason": "new conversation"})

    async def _restart_self(self, params: FunctionCallParams):
        import subprocess
        try:
            subprocess.Popen(["systemd-run", "--on-active=4", "--quiet",
                              "systemctl", "restart", "jarvis-voice-gateway"])
            await params.result_callback(
                "Restart scheduled in 4 seconds; the call will drop. Tell him to reconnect.")
        except Exception as exc:  # noqa: BLE001
            await params.result_callback(f"Could not schedule the restart: {exc}")

    # -- Tier 2: the whole agent, asynchronous ---------------------------------
    @tool_options(cancel_on_interruption=False, timeout_secs=ASK_JARVIS_TIMEOUT_S)
    async def _ask_jarvis(self, params: FunctionCallParams):
        request = str((params.arguments or {}).get("request") or "").strip()
        if not request:
            await params.result_callback("The request was empty; ask him what he wants done.")
            return
        norm = re.sub(r"[^a-z0-9 ]", "", request.lower())[:80]
        if norm in self._running and time.time() - self._running[norm] < ASK_JARVIS_TIMEOUT_S:
            await params.result_callback(
                "That exact task is ALREADY running from a moment ago; do not start it again. "
                "Tell him it is in progress and that you will report the result when it lands.")
            return
        self._running[norm] = time.time()
        await self._status("working", "JARVIS is on it")
        t0 = time.time()
        job: Dict[str, Any] = {"request": request, "started": t0, "status": "running", "notes": []}
        # The engine's own router sometimes answers "I can't do that from here"
        # instead of working (its fast Z.AI classifier picking mode=answer), and
        # for anything it grades "big" it asks "worker, or here?" - a question
        # that used to be relayed to him word for word and never answered
        # (2026-09-17, the file-drop call). "Take your time ... I'll wait" is
        # the phrase its rules map to: work it here, no offer, no 30 s check-in.
        directive = ("Take your time and finish it completely; I'll wait on the call. "
                     "Use your tools (terminal, files, PC bridge, email, calendar, web) "
                     "and report the actual result with specifics. Never reply that you "
                     "cannot or that you lack access: you are JARVIS on your own server. "
                     "Task: ")
        try:
            res = await self._dash.start_turn(directive + request, self._agent_thread)
            if str(res.get("mode") or "") == "offer":
                # Belt and braces: it still asked. This call IS the answer channel.
                res = await self._dash.start_turn("work it here with me, take your time",
                                                  self._agent_thread)
        except Exception as exc:  # noqa: BLE001
            await self._status("idle", "")
            await params.result_callback(
                f"Could not reach the JARVIS agent ({type(exc).__name__}). Tell him and offer to retry.")
            return
        turn_id = str(res.get("turn_id") or "")
        self.jobs[turn_id or request[:40]] = job
        if turn_id:
            # The engine asks "still there?" after 30 s of work and, unanswered,
            # may background the job to WhatsApp. This call IS the answer channel.
            await self._dash.interject(turn_id, "take your time, stay on it")
        # The engine may already have answered synchronously (fast path).
        mode = str(res.get("mode") or "")
        immediate = speakable(_clean_speech(str(res.get("say") or "")))
        answer = ""
        handoff = ""
        last_note = ""
        if turn_id:
            async for ev, payload in self._dash.events(turn_id):
                text = speakable(_clean_speech(str(payload.get("text") or "")))
                if ev in ("narration", "status", "plan") and text:
                    job["notes"].append(text)
                    if text != last_note:
                        last_note = text
                        # Screen only (data channel). NOT an intermediate
                        # result_callback: Pipecat turns those into developer
                        # messages that "defer" the final result into another
                        # developer message, and GLM then keeps the "still
                        # running" tool placeholder as the truth and never
                        # relays the answer (seen 2026-09-16). With no
                        # intermediate updates the result settles in place as
                        # an ordinary tool result, which the model relays.
                        await self._status("working", text[:80])
                elif ev in ("answer", "ask"):
                    answer = text or answer
                elif ev == "checkin":
                    await self._dash.interject(turn_id, "take your time, stay on it")
                elif ev == "handoff":
                    handoff = text or "Handed off; the result will land on his WhatsApp."
                elif ev == "error":
                    answer = answer or f"The agent hit an error: {text or 'unknown'}"
                elif ev == "end":
                    break
        if turn_id and not answer:
            # No spoken answer event (e.g. the engine thought he had left):
            # the turn record still holds the full reply.
            for _ in range(3):
                rec = await self._dash.result(turn_id)
                if rec.get("reply"):
                    answer = speakable(_clean_speech(str(rec.get("reply"))))
                    if rec.get("delivered"):
                        answer += " (Also sent in full to his WhatsApp.)"
                    break
                if rec.get("status") in ("done", "error", "unknown"):
                    break
                await asyncio.sleep(1.0)
        took = time.time() - t0
        job["status"] = "done"
        job["took_s"] = round(took, 1)
        await self._status("idle", "")
        final = answer or immediate or handoff
        if not final:
            final = "The agent finished but returned nothing to say."
        if mode in ("delegate", "big") and not answer:
            final = handoff or immediate or "Handed to a background worker; the result goes to WhatsApp."
        job["result"] = final[:500]
        self._running.pop(norm, None)
        logger.info("ask_jarvis done in {:.1f}s mode={} chars={}", took, mode, len(final))
        # 1) Settle the tool call in the context WITHOUT running the model on it.
        #    If he kept talking meanwhile, Pipecat can only record this as a
        #    "developer" message, which GLM reliably ignores (it keeps trusting
        #    the "still running" placeholder). So:
        await params.result_callback(
            f"DONE (took {took:.0f}s): {final[:4000]}",
            properties=FunctionCallResultProperties(run_llm=False))
        # 2) ...and deliver the result as an explicit system notice in the user
        #    channel, which every model treats as the thing to respond to now.
        task = self._task_getter() if self._task_getter else None
        if self._inject is not None or task is not None:
            notice = ("(Automatic system notice, not Enrique speaking.) The task you handed to the "
                      f"JARVIS agent is FINISHED — it took {took:.0f} seconds. This is its final "
                      f"answer, nothing more is coming for it: «{final[:3000]}». Tell Enrique the "
                      "result now in one or two natural spoken sentences (do not repeat anything you "
                      "already said about other topics), then carry on.")
            if self._inject is not None:
                await self._inject(notice)
            else:
                await task.queue_frame(LLMMessagesAppendFrame(
                    messages=[{"role": "user", "content": notice}], run_llm=True))


# ------------------------------------------------------------- warm-up --------
async def warm_prefix(system_prompt: str, tools_schema: ToolsSchema) -> None:
    """Fire one tiny completion with the exact system prompt + tool list so the
    provider's prefix cache is hot before his first real question (Fireworks
    caches prompt prefixes automatically; the first cold call measured 2.1 s
    TTFB vs ~0.6 s warm)."""
    if effective_brain() != "fireworks":
        return
    key = os.environ.get("FIREWORKS_API_KEY", "")
    if not key:
        return
    try:
        tools = [t.to_default_dict() if hasattr(t, "to_default_dict") else t
                 for t in (tools_schema.standard_tools or [])]
        tools = [{"type": "function", "function": t} if "function" not in t else t for t in tools]
        body = {"model": cfg("VOICE_FIREWORKS_MODEL", FIREWORKS_MODEL), "max_tokens": 1, "temperature": 0,
                "messages": [{"role": "system", "content": system_prompt},
                             {"role": "user", "content": "hi"}],
                "tools": tools, "reasoning_effort": "low"}
        t0 = time.time()
        async with httpx.AsyncClient(timeout=20.0) as c:
            await c.post("https://api.fireworks.ai/inference/v1/chat/completions",
                         headers={"Authorization": "Bearer " + key}, json=body)
        logger.info("prefix warm-up done in {:.0f} ms", (time.time() - t0) * 1000)
    except Exception as exc:  # noqa: BLE001 - best effort only
        log.debug("warm-up failed: %s", exc)


# --------------------------------------------------------------- LLM factory --
def make_llm(system_prompt: str | None = None):
    """Return (service, label). Import lazily so a missing optional package only
    breaks the provider that needs it. Reads live settings (voice.env) so the
    agent's own changes apply to the next call. For OpenAI Realtime the persona
    goes into the session's native `instructions` (the model weights it far more
    than a system item inside the conversation, which is how Pipecat relays a
    context system message)."""
    env = os.environ
    brain = effective_brain()
    if brain == "anthropic":
        key = env.get("ANTHROPIC_API_KEY", "")
        if not key:
            raise RuntimeError("VOICE_BRAIN=anthropic but ANTHROPIC_API_KEY is not set")
        from pipecat.services.anthropic.llm import AnthropicLLMService
        svc = AnthropicLLMService(api_key=key, model=ANTHROPIC_MODEL,
                                  params=AnthropicLLMService.InputParams(temperature=0.6,
                                                                         max_tokens=400))
        return svc, f"anthropic:{ANTHROPIC_MODEL}"
    if brain == "zai":
        from pipecat.services.openai.llm import OpenAILLMService
        key = env.get("ZAI_API_KEY_2", "") or env.get("ZAI_API_KEY", "")
        svc = OpenAILLMService(api_key=key, base_url=ZAI_BASE, model=ZAI_MODEL,
                               params=OpenAILLMService.InputParams(
                                   temperature=0.6, max_tokens=400,
                                   extra={"thinking": {"type": "disabled"}}))
        return svc, f"zai:{ZAI_MODEL}"
    if brain == "openai-realtime":
        key = env.get("OPENAI_API_KEY", "")
        if not key:
            raise RuntimeError("VOICE_BRAIN=openai-realtime but OPENAI_API_KEY is not set")
        from pipecat.services.openai.realtime import events as rt
        from pipecat.services.openai.realtime.llm import OpenAIRealtimeLLMService
        model = cfg("VOICE_OPENAI_MODEL", OPENAI_REALTIME_MODEL)
        voice = cfg("VOICE_OPENAI_VOICE", OPENAI_VOICE)
        eagerness = cfg("VOICE_OPENAI_EAGERNESS", OPENAI_EAGERNESS)
        effort = cfg("VOICE_OPENAI_REASONING", OPENAI_REASONING)
        try:
            speed = float(cfg("VOICE_OPENAI_SPEED", str(OPENAI_SPEED)))
        except ValueError:
            speed = OPENAI_SPEED
        reasoning = rt.Reasoning(effort=effort) if ("gpt-realtime-2" in model and effort) else None
        props = rt.SessionProperties(
            model=model,
            instructions=system_prompt or None,
            output_modalities=["audio"],
            audio=rt.AudioConfiguration(
                input=rt.AudioInput(
                    format=rt.PCMAudioFormat(),
                    transcription=rt.InputAudioTranscription(language="en", prompt=None),
                    noise_reduction=rt.InputAudioNoiseReduction(type="near_field"),
                    turn_detection=rt.SemanticTurnDetection(
                        eagerness=eagerness, create_response=True,
                        interrupt_response=True),
                ),
                output=rt.AudioOutput(format=rt.PCMAudioFormat(), voice=voice, speed=speed),
            ),
            tool_choice="auto",
            # Audio tokens count against this (~20 tokens/s of speech): 220 cut
            # every reply at ~10 s ("it always cuts off the last few lines").
            # Brevity is the prompt's job; this is only a runaway guard (~50 s).
            max_output_tokens=1000,
            reasoning=reasoning,
        )
        # Barge-in gate: the stock service truncates + interrupts on EVERY
        # input_audio_buffer.speech_started, including speaker echo of the
        # bot's own voice and backchannels — that is what chopped phrases and
        # stacked responses on 2026-09-23. The gate holds sounds that start
        # while bot audio is playing for GATE_SPEAK_MIN_S before letting them
        # interrupt; real barge-in (persistent speech) passes, blips are
        # dropped. Quiet-path latency is untouched.
        try:
            from rt_echo_guard import EchoGuardRealtimeLLMService
            svc = EchoGuardRealtimeLLMService(api_key=key, model=model,
                                              session_properties=props)
        except ImportError:
            log.warning("rt_echo_guard unavailable; stock realtime service")
            svc = OpenAIRealtimeLLMService(api_key=key, model=model,
                                           session_properties=props)
        return svc, f"openai:{model}/{voice}"
    from pipecat.services.fireworks.llm import FireworksLLMService
    key = env.get("FIREWORKS_API_KEY", "")
    if not key:
        raise RuntimeError("FIREWORKS_API_KEY is not set (voice brain default)")
    fw_model = cfg("VOICE_FIREWORKS_MODEL", FIREWORKS_MODEL)
    svc = FireworksLLMService(api_key=key, model=fw_model,
                              params=FireworksLLMService.InputParams(
                                  temperature=0.6, max_tokens=260,
                                  extra={"reasoning_effort": "low"}))
    return svc, f"fireworks:{fw_model.rsplit('/', 1)[-1]}"
