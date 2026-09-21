#!/usr/bin/env python3
"""JARVIS session/cron naming agent + project tagging (Feedback Round 2, items 1-2).

What it does
------------
1.  TITLES: gives every cron job and every recent work session a short,
    glanceable title (2-4 words, LLM-generated, cached by content hash).
    - cron jobs      -> 'title' field written back into /root/.hermes/cron/jobs.json
    - work sessions  -> title + title_source='llm' written into the Hermes
                        session store via SessionDB.set_auto_title
    Titles are cached in ~/.hermes/cache/session_naming.json (keyed by
    id + content hash) so re-runs are free and an already-titled item whose
    content did not change is never re-titled.

2.  PROJECT TAGS: fixes the "everything lands in jarvis system" grouping by
    classifying each work session into a real project and exposing the map
    to the iOS app. Tags are stored in the same cache file and served by the
    jarvis-ios-bridge /projects/meta endpoint (dashboard APIs cannot carry a
    custom per-session field without patching Hermes core).

Fast by design: Fireworks GLM (fast tier), ~100-token replies, per-item
cache, concurrency 6, hard 45s timeout per item with rule-based fallbacks.

Run:  python3 session_naming.py [--limit N] [--dry-run] [--retag]
"""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "/root/.hermes"))
CACHE_PATH = HERMES_HOME / "cache" / "session_naming.json"
CONFIG_PATH = HERMES_HOME / "config.yaml"
ENV_PATH = HERMES_HOME / ".env"

MAX_TITLE_WORDS = 4
LLM_TIMEOUT_S = 45
WORKERS = 6
MAX_INPUT_CHARS = 400

# Projects the iOS app groups by (order = display order).
KNOWN_PROJECTS = [
    "ticketflipping",
    "krendora",
    "home-budget",
    "jarvis-ios",
    "jarvis-system",
    "personal",
    "other",
]

# Rule-based keyword tags (checked before/instead of the LLM; cheap + stable).
KEYWORD_TAGS = [
    ("jarvis-ios", ["jarvis-ios", "ios app", "testflight", "swiftui", "xcode",
                    "sessionsview", "callkit", "apns", "jarvis ios"]),
    ("home-budget", ["home-budget", "home budget", "presupuesto"]),
    ("ticketflipping", ["ticketflipping", "ticket flipping", "tf scraper",
                        "broker copilot", "tmapi", "tftbox", "flare",
                        "contractor log", "contractor timesheet", "tf "]),
    ("krendora", ["krendora", "aidp", "instagram account", "ig account",
                  "ig fleet", "shopify", "drop-shipping", "dropshipping",
                  "fb messenger", "facebook inbox"]),
    ("jarvis-system", ["jarvis system", "hermes", "gateway", "dashboard",
                       "voice gateway", "cron", "voice call", "agent loop"]),
]

_TITLE_SYSTEM = (
    "You name JARVIS work sessions and cron jobs. Reply with JSON only: "
    '{"title": "..."} — 2 to 4 words, sentence case, specific and glanceable. '
    "Name WHAT it does (e.g. 'Contractor Log Filler', 'Krendora IG Sync'), "
    "not the request text. Never answer the prompt. No quotes or punctuation."
)

_PROJECT_SYSTEM = (
    "Classify a JARVIS work session into exactly one project. Reply JSON only: "
    '{"project": "..."} where project is one of: ticketflipping, krendora, '
    "home-budget, jarvis-ios, jarvis-system, personal, other. "
    "jarvis-system means JARVIS/Hermes infrastructure work (voice, gateway, "
    "dashboard, agent itself). personal = Enrique's life/admin, not a codebase."
)


# ---------------------------------------------------------------- infra ----

def _load_env_file() -> None:
    if not ENV_PATH.exists():
        return
    for line in ENV_PATH.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def _llm_client():
    """Fast-tier OpenAI-compatible client. Prefers Fireworks (fastest),
    falls back to the box's zaicoding pools."""
    import yaml
    import openai

    cfg = yaml.safe_load(CONFIG_PATH.read_text())
    providers = cfg.get("providers") or {}
    for name in ("fireworks", "zaicoding", "zaicoding2"):
        p = providers.get(name)
        if not p:
            continue
        key = os.environ.get(p.get("key_env") or "")
        if not key:
            continue
        try:
            return openai.OpenAI(
                base_url=p["api"], api_key=key, timeout=LLM_TIMEOUT_S
            ), p.get("default_model")
        except Exception:
            continue
    return None, None


_CLIENT = None
_MODEL = None


def _chat(system: str, user: str, max_tokens: int = 300) -> str | None:
    """One small LLM call -> raw content or None. Never raises."""
    global _CLIENT, _MODEL
    try:
        if _CLIENT is None:
            _CLIENT, _MODEL = _llm_client()
            if _CLIENT is None:
                return None
        r = _CLIENT.chat.completions.create(
            model=_MODEL,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user[:MAX_INPUT_CHARS]},
            ],
            max_tokens=max_tokens,
            temperature=0.3,
        )
        return (r.choices[0].message.content or "").strip()
    except Exception as e:
        print(f"  [warn] llm call failed: {e}", file=sys.stderr)
        return None


def _json_field(raw: str | None, field: str) -> str | None:
    if not raw:
        return None
    m = re.search(rf'"{field}"\s*:\s*"([^"]+)"', raw)
    return m.group(1).strip() if m else None


def _content_hash(*parts: str) -> str:
    return hashlib.sha1("||".join(p or "" for p in parts).encode()).hexdigest()[:12]


def _load_cache() -> dict:
    try:
        return json.loads(CACHE_PATH.read_text())
    except Exception:
        return {"titles": {}, "projects": {}}


def _save_cache(cache: dict) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache, indent=1))
    tmp.replace(CACHE_PATH)


def _clean_title(t: str | None, fallback: str) -> str:
    if not t:
        return fallback
    t = re.sub(r'\s+', ' ', t).strip().strip('"').strip()
    words = t.split()
    if not words or len(words) > MAX_TITLE_WORDS + 2:
        return fallback
    return " ".join(words[:MAX_TITLE_WORDS])


def _fallback_title(name: str, text: str) -> str:
    """Rule-based title when the LLM is unavailable."""
    base = re.sub(r"[-_.]+", " ", name or "").strip()
    words = base.split()[:MAX_TITLE_WORDS]
    if words:
        return " ".join(w.capitalize() if not w.isupper() else w for w in words)
    return " ".join((text or "work session").split()[:MAX_TITLE_WORDS])


def _rule_project(text: str) -> str | None:
    low = (text or "").lower()
    for project, kws in KEYWORD_TAGS:
        if any(k in low for k in kws):
            return project
    return None


# ------------------------------------------------------------ cron jobs ----

def load_cron_jobs() -> list[dict]:
    jobs_path = HERMES_HOME / "cron" / "jobs.json"
    data = json.loads(jobs_path.read_text())
    return data.get("jobs", [])


def save_cron_jobs(jobs: list[dict]) -> None:
    jobs_path = HERMES_HOME / "cron" / "jobs.json"
    data = json.loads(jobs_path.read_text())
    data["jobs"] = jobs
    tmp = jobs_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(jobs_path)


def _job_text(job: dict) -> str:
    return " ".join(
        str(job.get(k) or "") for k in ("name", "prompt", "script")
    )[:MAX_INPUT_CHARS]


def title_cron_jobs(dry_run: bool = False) -> list[tuple[str, str, str]]:
    """Returns list of (job_id, old_title_or_name, new_title)."""
    jobs = load_cron_jobs()
    cache = _load_cache()
    results: list[tuple[str, str, str]] = []

    def _one(job: dict):
        jid = job.get("id", "")
        text = _job_text(job)
        key = f"{jid}:{_content_hash(text)}"
        cached = cache["titles"].get(key)
        if cached:
            return jid, cached
        raw = _chat(_TITLE_SYSTEM, f"Job: {job.get('name')}. Details: {text}")
        title = _clean_title(_json_field(raw, "title"),
                             _fallback_title(job.get("name"), text))
        return jid, title

    with futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = {ex.submit(_one, j): j for j in jobs}
        titled: dict[str, str] = {}
        for fut in futures.as_completed(futs):
            job = futs[fut]
            try:
                jid, title = fut.result()
            except Exception as e:
                print(f"  [warn] title {job.get('id')}: {e}", file=sys.stderr)
                continue
            titled[jid] = title
            old = job.get("title") or job.get("name") or jid
            if title and title != old:
                results.append((jid, old, title))
    if not dry_run:
        for j in jobs:
            t = titled.get(j.get("id", ""))
            if t:
                j["title"] = t
        save_cron_jobs(jobs)
    return results


# ---------------------------------------------------------- work sessions --

def _open_db():
    sys.path.insert(0, "/usr/local/lib/hermes-agent")
    from hermes_state import SessionDB
    return SessionDB()


def recent_work_sessions(db, limit: int = 40, min_msgs: int = 4) -> list[dict]:
    rows = db.list_recent_sessions_bounded(limit=limit, exclude_sources=["cron"])
    return [r for r in rows if (r.get("message_count") or 0) >= min_msgs]


def _session_text(db, sid: str) -> str:
    try:
        msgs = db.get_messages(sid, limit=4)
        parts = []
        for m in msgs:
            role = m.get("role")
            if role == "tool":
                continue
            c = (m.get("content") or "")
            if c.startswith("[CONTEXT COMPACTION"):
                c = c[:200]
            parts.append(f"{role}: {c[:220]}")
        return " ".join(parts)[:MAX_INPUT_CHARS]
    except Exception:
        return ""


def title_sessions(db, dry_run: bool = False, retag: bool = False) -> list[tuple[str, str, str]]:
    """Returns (session_id, old_title, new_title). Also refreshes project tags."""
    cache = _load_cache()
    sessions = recent_work_sessions(db)
    results: list[tuple[str, str, str]] = []
    new_projects = {}

    def _one(sess: dict):
        sid = sess["id"]
        text = _session_text(db, sid)
        key = f"{sid}:{_content_hash(text)}"
        cached_title = cache["titles"].get(key)
        if cached_title and not retag:
            return sid, cached_title, None, text
        raw = _chat(_TITLE_SYSTEM, f"Session: {sess.get('title') or sid}. Transcript: {text}")
        title = _clean_title(_json_field(raw, "title"),
                             _fallback_title(sess.get("title"), text))
        return sid, title, key, text

    with futures.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = {ex.submit(_one, s): s for s in sessions}
        for fut in futures.as_completed(futs):
            sess = futs[fut]
            sid = sess["id"]
            try:
                sid, title, key, text = fut.result()
            except Exception as e:
                print(f"  [warn] session {sid}: {e}", file=sys.stderr)
                continue
            old = sess.get("title") or sid
            if title and old.startswith(title):
                # DB already holds this title (possibly date-qualified); keep it
                title = old
            if title and title != old:
                results.append((sid, old, title))
            if not dry_run and title:
                if key:
                    cache["titles"][key] = title
                try:
                    if not db.set_auto_title(sid, title, source="llm"):
                        # an equal-authority (llm) title already holds the row;
                        # an explicit naming-agent rename is authoritative.
                        db.set_session_title(sid, title)
                except Exception as e:
                    # uniqueness violation -> qualify with the session date
                    if "already in use" in str(e):
                        qual = f"{title} {sid[4:6]}/{sid[6:8]}"
                        try:
                            db.set_session_title(sid, qual)
                            title = qual
                        except Exception as e2:
                            print(f"  [warn] set title {sid}: {e2}", file=sys.stderr)
                    else:
                        print(f"  [warn] set title {sid}: {e}", file=sys.stderr)
            # project tag
            project = _rule_project(text) or _json_field(
                _chat(_PROJECT_SYSTEM, text), "project") or "other"
            if project not in KNOWN_PROJECTS:
                project = "other"
            new_projects[sid] = project

    if not dry_run:
        cache["projects"].update(new_projects)
        cache["projects_updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        _save_cache(cache)
    return results


# ------------------------------------------------------------------- CLI --

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=40)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--retag", action="store_true",
                    help="re-run project classification even if title cached")
    args = ap.parse_args()

    _load_env_file()
    print("== cron jobs ==")
    cron_changes = title_cron_jobs(dry_run=args.dry_run)
    for jid, old, new in cron_changes:
        print(f"  {jid[:12]}  {old!r} -> {new!r}")
    print(f"  {len(cron_changes)} cron titles changed")

    print("== work sessions ==")
    db = _open_db()
    sess_changes = title_sessions(db, dry_run=args.dry_run, retag=args.retag)
    for sid, old, new in sess_changes:
        print(f"  {sid}  {old!r} -> {new!r}")
    print(f"  {len(sess_changes)} session titles changed")

    cache = _load_cache()
    print("== project tags ==")
    for sid, project in cache.get("projects", {}).items():
        print(f"  {sid} -> {project}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
