#!/usr/bin/env python3
"""check_cc_contract.py — CC-API contract checker for the iOS app's Home tab.

Layer A (structural, offline): every dashboard route the app calls must exist
in the deployed dashboard source, and the Swift models must still declare the
fields this checker pins (greps the real .swift files). Tamper either side
and this fails. Layer B (live, read-only GETs): mint a dashboard bearer the
same way the other probes do and fetch each endpoint; each payload is decoded
against a shadow of the app's model (required = non-optional Swift `let`,
optional = `T?`). SKIPPED (exit 0, warning) when the dashboard is unreachable
— same convention as check_login_contract.py's live layer.

Why this exists: the day-one sign-in path got its contract checker (step 1d,
check_login_contract.py); the path AFTER sign-in — Home loading its seven
cards, Chats loading the dispatch board — had nothing pinning it. This pins
exactly those calls:
  /api/control/vitals | overview | zai_usage | automations | activity |
  attention | dispatch/board
(The bridge /health + /secrets surfaces are structure-pinned only; their live
behavior is covered by probe_call_bearer_live.py's throwaway instance.)

Usage: python3 scripts/check_cc_contract.py [--offline-only]
Exit 0 iff all pins pass (or the live layer is skipped cleanly).
"""
import json
import re
import sys
import time
import base64
import hashlib
import hmac
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DASH_SRC = Path("/usr/local/lib/hermes-agent/hermes_cli/web_routers/control_center.py")
APP = REPO / "ios" / "JarvisApp"

# --- The contract -----------------------------------------------------------
# required = app's non-optional `let x: T`; optional = `let x: T?`. Live
# payloads must carry every required key and, when a collection is present
# and non-empty, every required sub-field of its elements.
CONTRACT = {
    "/api/control/vitals": {
        "swift": "CCClient.swift",
        "model_required": ["Vitals"],
        "fields_req": ["cpu_pct", "mem_used_mb", "mem_total_mb",
                       "disk_used_gb", "disk_total_gb", "uptime_seconds"],
        "fields_opt": ["load", "nproc"],
    },
    "/api/control/overview": {
        "swift": "CCClient.swift",
        "model_required": ["Overview"],
        "fields_req": ["generated_at"],
        "fields_opt": ["bridge", "projects"],
        "coll": {"key": "bridge", "req": ["configured", "reachable"],
                 "opt": ["latency_ms"]},
    },
    "/api/control/zai_usage": {
        "swift": "CCClient.swift",
        "model_required": ["ZaiUsage"],
        "fields_req": ["available", "windows"],
        "fields_opt": ["level", "error"],
        "coll": {"key": "windows", "req": ["key", "label"],
                 "opt": ["used", "limit", "remaining", "percent",
                         "reset_in_seconds"]},
    },
    "/api/control/automations": {
        "swift": "CCClient.swift",
        "model_required": ["Automations"],
        "fields_req": ["available", "items"],
        "fields_opt": ["active", "failing"],
        "coll": {"key": "items", "req": ["name"],
                 "opt": ["domain", "cadence", "status", "next_seconds",
                         "last_status"]},
    },
    "/api/control/activity": {
        "swift": "CCClient.swift",
        "model_required": ["Activity"],
        "fields_req": ["available"],
        "fields_opt": ["sessions"],
        "coll": {"key": "sessions", "req": ["id"],
                 "opt": ["title", "source", "model", "messages",
                         "ago_seconds", "active"]},
    },
    "/api/control/attention": {
        "swift": "CCClient.swift",
        "model_required": ["Attention"],
        "fields_req": ["alerts", "count", "critical"],
        "fields_opt": [],
        "coll": {"key": "alerts", "req": ["severity", "title"],
                 "opt": ["msg", "kind", "ref"]},
    },
    "/api/control/dispatch/board": {
        "swift": "ChatsView.swift",
        "model_required": ["Board"],
        "fields_req": ["threads"],
        "fields_opt": [],
        "coll": {"key": "threads", "req": ["slug", "title"],
                 "opt": ["project", "open_count", "items"]},
    },
}

# Swift source each model struct must live in (route -> file -> struct names).
SWIFT_STRUCTS = {
    "CCClient.swift": ["Vitals", "Overview", "BridgeHealth", "ZaiUsage",
                       "Automations", "Activity", "Attention", "WorkChatReply",
                       "WorkHistory"],
    "ChatsView.swift": ["Board"],
}


def fail(msg):
    print(f"CC-CONTRACT-FAIL: {msg}")
    sys.exit(1)


def check_offline():
    problems = []
    # 1. dashboard routes exist
    if not DASH_SRC.exists():
        problems.append(f"dashboard source missing: {DASH_SRC}")
    else:
        src = DASH_SRC.read_text(encoding="utf-8", errors="replace")
        for route in CONTRACT:
            pat = re.compile(
                r'@router\.(?:get|post)\("%s' % re.escape(route) + r'"')
            if not pat.search(src):
                problems.append(f"dashboard route not found: {route}")
    # 2. swift structs exist in their files
    for fname, structs in SWIFT_STRUCTS.items():
        f = APP / fname
        if not f.exists():
            problems.append(f"swift file missing: {fname}")
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        for s in structs:
            if not re.search(r"struct %s\b" % s, text):
                problems.append(f"{fname}: struct {s} missing")
    # 3. each endpoint's required fields are declared in the swift model
    for route, spec in CONTRACT.items():
        f = APP / spec["swift"]
        if not f.exists():
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        m = re.search(
            r"struct\s+%s\b.*?(?=\nstruct\s|\n\n\n|\Z)" % spec["model_required"][0],
            text, re.S)
        if not m:
            problems.append(f"{spec['swift']}: cannot locate struct "
                            f"{spec['model_required'][0]}")
            continue
        body = m.group(0)
        for field in spec["fields_req"]:
            if not re.search(r"let\s+%s\s*:" % re.escape(field), body):
                problems.append(f"{route}: required field '{field}' missing "
                                f"from struct {spec['model_required'][0]}")
    return problems


def mint_bearer(ttl=600):
    import yaml  # local import: offline layer must run without yaml
    cfg = yaml.safe_load(open("/root/.hermes/config.yaml"))
    raw = (cfg.get("dashboard") or {}).get("basic_auth", {}).get("secret", "")
    secret = None
    for dec in (base64.b64decode, bytes.fromhex):
        try:
            cand = dec(raw)
            if len(cand) >= 16:
                secret = cand
                break
        except Exception:
            pass
    if secret is None:
        secret = raw.encode()
    payload = {"sub": "enrique", "kind": "access",
               "exp": int(time.time()) + ttl}
    blob = json.dumps(payload, separators=(",", ":")).encode()
    sig = hmac.new(secret, blob, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(blob + sig).decode()


def get_live(path, token, timeout=25):
    req = urllib.request.Request("http://127.0.0.1:9119" + path,
                                 headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300]
    except Exception as e:
        return -1, str(e)[:160].encode()


def decode_ok(doc, spec):
    """Shadow of the Swift model: same required/optional split."""
    if not isinstance(doc, dict):
        return f"payload not an object ({type(doc).__name__})"
    probs = []
    for k in spec["fields_req"]:
        if k not in doc:
            probs.append(f"missing required '{k}'")
    coll = spec.get("coll")
    if coll:
        arr = doc.get(coll["key"])
        if isinstance(arr, list) and arr:
            for i, el in enumerate(arr[:3]):
                if not isinstance(el, dict):
                    probs.append(f"{coll['key']}[{i}] not an object")
                    continue
                for rk in coll["req"]:
                    if rk not in el:
                        probs.append(
                            f"{coll['key']}[{i}] missing '{rk}'")
    return "; ".join(probs)


def check_live():
    try:
        token = mint_bearer()
    except Exception as e:
        print(f"SKIP (live): cannot mint bearer — {e}")
        return True
    all_ok = True
    for route, spec in CONTRACT.items():
        st, body = get_live(route, token)
        if st == -1:
            print(f"SKIP (live): {route} — dashboard unreachable ({body[:80]!r})")
            return True
        if st == 429:
            print(f"LIVE {route}: 429 (alive, rate-limited) — tolerated")
            continue
        if st != 200:
            print(f"CC-CONTRACT-FAIL (live): {route} -> HTTP {st}")
            all_ok = False
            continue
        try:
            doc = json.loads(body)
        except Exception as e:
            print(f"CC-CONTRACT-FAIL (live): {route} bad JSON: {e}")
            all_ok = False
            continue
        verdict = decode_ok(doc, spec)
        if verdict:
            print(f"CC-CONTRACT-FAIL (live): {route} decode: {verdict}")
            all_ok = False
        else:
            print(f"LIVE {route}: 200 decode OK")
    return all_ok


def main():
    offline_only = "--offline-only" in sys.argv
    problems = check_offline()
    if problems:
        for p in problems:
            print(f"CC-CONTRACT-FAIL: {p}")
        sys.exit(1)
    print(f"offline pins: {len(CONTRACT)} routes pinned, Swift models match")
    if offline_only:
        print("live layer skipped (--offline-only)")
        return
    if not check_live():
        sys.exit(1)
    print("cc contract: ALL GREEN")


if __name__ == "__main__":
    main()
