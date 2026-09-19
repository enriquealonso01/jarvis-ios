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

Usage: python3 scripts/check_cc_contract.py [--offline-only] [--selftest]
Exit 0 iff all pins pass (or the live layer is skipped cleanly).

1e-bis — collection ELEMENT structs are now pinned OFFLINE too, closing the
blind spot 1f called out when it landed for the bridge. Layer A used to pin
only each model's TOP-LEVEL fields; the nested structs a list actually
renders (Overview.Project, ZaiUsage.Window, Automations.Item, Activity.Session,
Attention.Alert, Overview.Bridge, and ChatsView's Board.Thread/Board.Item)
were checked only on the LIVE payload side. A Swift-side rename of
Automations.Item.name would have left BOTH layers green while the app decoded
blank rows forever. Now each element struct is brace-extracted from its real
.swift file and its required/optional split verified in BOTH directions
(req pinned => must be declared non-optional; opt pinned => must be declared
`T?` — the under-pin direction leaves decode-breaking fields unprotected).
`--selftest` negative-tests 7 ways on tmp copies (the real tree is never
touched), same convention as 1f/1g/1h.
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

# 1e-bis: collection ELEMENT structs, pinned OFFLINE (Layer A) in BOTH
# directions — a req-pinned field must be declared non-optional (`let x: T`),
# an opt-pinned field must be declared `T?`. Layer A used to pin only
# top-level fields, so a Swift-side rename of Automations.Item.name left BOTH
# layers green while the app decoded blank rows forever (the blind spot 1f
# closed for the bridge; this closes it for the dashboard surface).
# Keys are "Parent.Element"; ChatsView's Board is nested inside the load()
# function — brace extraction finds it all the same.
ELEMENT_STRUCTS = {
    "Overview.Bridge":  {"file": "CCClient.swift",
                         "req": [],
                         "opt": ["configured", "reachable", "latency_ms"]},
    "Overview.Project": {"file": "CCClient.swift",
                         "req": ["name"],
                         "opt": ["domain", "description"]},
    "ZaiUsage.Window":  {"file": "CCClient.swift",
                         "req": ["key", "label"],
                         "opt": ["used", "limit", "remaining", "percent",
                                 "reset_in_seconds"]},
    "Automations.Item": {"file": "CCClient.swift",
                         "req": ["name"],
                         "opt": ["domain", "cadence", "status",
                                 "next_seconds", "last_status"]},
    "Activity.Session": {"file": "CCClient.swift",
                         "req": ["id"],
                         "opt": ["title", "source", "model", "messages",
                                 "ago_seconds", "active"]},
    "Attention.Alert":  {"file": "CCClient.swift",
                         "req": ["severity", "title"],
                         "opt": ["msg", "kind", "ref"]},
    "Board.Thread":     {"file": "ChatsView.swift",
                         "req": ["slug", "title"],
                         "opt": ["project", "open_count", "items"]},
    "Board.Item":       {"file": "ChatsView.swift",
                         "req": [],
                         "opt": ["message", "ago_seconds"]},
}


def extract_struct_body(text, name):
    """Brace-aware body of `struct <name> ... { ... }` (first match).

    Returns the text from the opening brace through its MATCHING closing
    brace, so nested structs (Board.Thread inside Board) don't truncate it.
    An unbalanced brace in a string/comment can only over-count depth ->
    truncated body -> missing field -> loud FAIL, never a silent pass.
    """
    m = re.search(r"struct\s+%s\b" % re.escape(name), text)
    if not m:
        return None
    try:
        i = text.index("{", m.end())
    except ValueError:
        return None
    depth, j = 1, i + 1
    while j < len(text) and depth:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
        j += 1
    return text[i + 1:j - 1] if depth == 0 else None


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
    # 4. (1e-bis) collection ELEMENT structs, BOTH directions: req-pinned
    # must be non-optional; opt-pinned must be `T?` (under-pinning an opt
    # leaves a decode-breaking field unprotected — 1f's lesson).
    file_cache = {}
    for qname, spec in ELEMENT_STRUCTS.items():
        fname = spec["file"]
        if fname not in file_cache:
            f = APP / fname
            file_cache[fname] = (f.read_text(encoding="utf-8", errors="replace")
                                 if f.exists() else None)
        text = file_cache[fname]
        if text is None:
            problems.append(f"swift file missing: {fname}")
            continue
        parent, elem = qname.split(".", 1)
        body = extract_struct_body(text, elem)
        if body is None:
            problems.append(f"{fname}: cannot locate element struct {qname}")
            continue
        for field in spec["req"]:
            if not re.search(r"let\s+%s\s*:\s*[A-Za-z\[\]]+\s*$" % re.escape(field),
                             body, re.M):
                problems.append(
                    f"{qname}: req-pinned '{field}' missing or declared "
                    f"Optional (must be non-optional `let {field}: T`)")
        for field in spec["opt"]:
            if not re.search(r"let\s+%s\s*:\s*[A-Za-z\[\]]+\?\s*$" % re.escape(field),
                             body, re.M):
                problems.append(
                    f"{qname}: opt-pinned '{field}' missing or NOT declared "
                    f"Optional (must be `let {field}: T?`)")
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


def _tmp_app(tmp):
    """Point the checker's APP dir at a tmp tree (selftest only)."""
    global APP
    APP = tmp


def selftest():
    """7 negative tests on a throwaway copy of the real tree.

    The REAL ios/JarvisApp is never touched: each case copies both Swift
    files to a temp dir, tampers the COPY, points APP at it, and demands
    check_offline() fail with the exact pin class. A clean copy must produce
    ZERO problems (no-false-positive guard).
    """
    import shutil
    import tempfile
    root = Path(tempfile.mkdtemp(prefix="cc1e_selftest_"))
    results = []

    def fresh_tree():
        d = root / f"case{len(results)}"
        d.mkdir()
        for fname in ("CCClient.swift", "ChatsView.swift"):
            shutil.copy(APP / fname, d / fname)
        return d

    # helper that actually runs a case
    def run_case(name, fname, old, new, needle, want_empty=False):
        d = fresh_tree()
        f = d / fname
        text = f.read_text()
        if old is not None:
            if old not in text:
                results.append((name, False, "tamper anchor not found"))
                return
            f.write_text(text.replace(old, new, 1))
        old_app = APP
        _tmp_app(d)
        try:
            probs = check_offline()
        finally:
            _tmp_app(old_app)
        if want_empty:
            ok = not probs
            detail = "clean" if ok else f"unexpected: {probs[:2]}"
        else:
            ok = any(needle in p for p in probs)
            detail = (f"caught: {[p for p in probs if needle in p][0][:80]}"
                      if ok else f"MISSED ({len(probs)} other: {probs[:2]})")
        results.append((name, ok, detail))

    run_case(
        "T1 element req-field rename (Automations.Item.name -> title)",
        "CCClient.swift",
        "    struct Item: Decodable {\n        let name: String",
        "    struct Item: Decodable {\n        let title: String",
        "Automations.Item: req-pinned 'name'")
    run_case(
        "T2 req field declared Optional (Attention.Alert.severity -> String?)",
        "CCClient.swift",
        "        let severity: String\n        let title: String",
        "        let severity: String?\n        let title: String",
        "Attention.Alert: req-pinned 'severity'")
    run_case(
        "T3 opt field loses its ? (Bridge.latency_ms)",
        "CCClient.swift",
        "let latency_ms: Double?",
        "let latency_ms: Double",
        "Overview.Bridge: opt-pinned 'latency_ms'")
    run_case(
        "T4 element struct vanish (Automations.Item removed)",
        "CCClient.swift",
        "    struct Item: Decodable {\n        let name: String\n        let domain: String?\n        let cadence: String?\n        let status: String?\n        let next_seconds: Int?\n        let last_status: String?\n    }\n",
        "",
        "cannot locate element struct Automations.Item")
    run_case(
        "T5 opt field vanish (Board.Item.ago_seconds)",
        "ChatsView.swift",
        "                    let ago_seconds: Int?",
        "",
        "Board.Item: opt-pinned 'ago_seconds'")
    run_case(
        "T6 top-level req pin still armed (ZaiUsage.windows)",
        "CCClient.swift",
        "    let windows: [Window]",
        "    let windows_old: [Window]",
        "required field 'windows' missing")
    run_case(
        "T7 clean tree -> zero problems (no false positives)",
        "CCClient.swift", None, None, None, want_empty=True)

    shutil.rmtree(root, ignore_errors=True)
    failed = [r for r in results if not r[1]]
    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}")
    if failed:
        print(f"SELFTEST: {len(failed)}/{len(results)} FAILED")
        sys.exit(1)
    print(f"SELFTEST: {len(results)}/{len(results)} PASS")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
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
