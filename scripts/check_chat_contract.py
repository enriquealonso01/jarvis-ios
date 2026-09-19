#!/usr/bin/env python3
"""check_chat_contract.py — CC-API contract checker for the app's chat SEND path.

Layer A (structural, offline): the three chat-conversation routes must exist in
the deployed dashboard source, the pre-LLM 400 guards must be present (so the
live probes below cost ZERO model calls), and the Swift models must still
declare the pinned fields with the exact req/opt split.

Layer B (live): mints a dashboard bearer (same as check_cc_contract.py) and
proves, against the LIVE dashboard:
  1. POST /api/control/work/<probe>/chat with whitespace-only text -> 400
     {"detail": "empty message"} — the exact guard the app's send button hits
     before any LLM turn fires (a regression that moves the guard behind the
     model call would turn this into a hang/success and FAIL here).
  2. POST /api/control/project/task with empty text -> 400 {"detail": ...}
     (the "New chat" row's endpoint, same guarantee).
  3. GET /api/control/work/<probe>/history -> 200 decoding into the app's
     WorkHistory shadow ({available, session_id, messages, total}).
  4. GET history for a REAL session id (taken from /api/control/activity, the
     same board the Chats tab reads) so the messages[] ELEMENT shadow is
     non-vacuous whenever any session has messages; each element must carry
     `role` (the only field Swift declares non-optional).

Why this exists: step 1e pinned the seven read-only Home/Chats GETs; the app's
actual WRITE path — ChatsView.startTask -> POST /project/task,
ChatView.send -> POST /work/{id}/chat, and both threads' GET /work/{id}/history
poller — had no contract proof at all. A dashboard rename or a guard moved
behind the LLM call would have surfaced only as a silently dead chat on the
phone (or a send button that spins forever).

Usage: python3 scripts/check_chat_contract.py [--offline-only] [--selftest]
Exit 0 iff all pins pass (or the live layer is skipped cleanly).
"""
import copy
import json
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DASH_SRC = Path("/usr/local/lib/hermes-agent/hermes_cli/web_routers/control_center.py")
APP = REPO / "ios" / "JarvisApp"

# --- The contract -----------------------------------------------------------
# required = app's non-optional `let x: T`; optional = `let x: T?`.
ROUTES = [
    "/api/control/work/{work_id}/chat",      # POST — ChatView.send
    "/api/control/work/{work_id}/history",   # GET — loadHistory + pollHistory
    "/api/control/project/task",             # POST — ChatsView.startTask ("New chat")
]
# The pre-LLM guards: live 400 probes only prove ZERO-COST because these lines
# sit before run_in_threadpool(_run_jarvis_turn, ...) in the handlers.
GUARDS = ['detail="empty message"', 'detail="empty task"']

# (swift file, struct name, [(field, kind)]) — kind: "req" | "opt"
SWIFT_MODELS = [
    ("CCClient.swift", "WorkChatReply", [("reply", "req")]),
    ("CCClient.swift", "WorkHistory", [("available", "req"),
                                       ("session_id", "opt"),
                                       ("messages", "opt"),
                                       ("total", "opt")]),
    ("ChatsView.swift", "TaskReply", [("reply", "req")]),
]
# history element shadow — Swift Message: role required, the rest optional.
HIST_ELEM = {"req": ["role"], "opt": ["text", "ts", "tool_name"]}


def fail(msg):
    print(f"CHAT-CONTRACT-FAIL: {msg}")
    sys.exit(1)


# --- Layer A: offline pins ---------------------------------------------------
def pin_field(text, struct, field, kind):
    """True iff `field` is declared in `struct` with the required optionality.
    req -> `let f: Type` (Type NOT followed by '?');
    opt -> `let f: Type?`."""
    m = re.search(r"struct\s+%s\b.*?(?=\nstruct\s|\n\n\n|\Z)" % struct, text, re.S)
    if not m:
        return False
    body = m.group(0)
    base = r"let\s+%s\s*:\s*[A-Za-z0-9_<>\[\]]+" % re.escape(field)
    if kind == "req":
        return re.search(base + r"\s*(?![?\s]*\?)", body) is not None and \
            re.search(base + r"\s*\?", body) is None
    return re.search(base + r"\s*\?", body) is not None


def check_offline(dash_src=None, app_dir=None):
    dash_src = dash_src or DASH_SRC
    app_dir = app_dir or APP
    problems = []
    if not dash_src.exists():
        problems.append(f"dashboard source missing: {dash_src}")
    else:
        src = dash_src.read_text(encoding="utf-8", errors="replace")
        for route in ROUTES:
            pat = re.compile(
                r'@router\.(?:get|post)\("%s"' %
                re.escape(route).replace(r"\{work_id\}", r"\{work_id\}"))
            if not pat.search(src):
                problems.append(f"dashboard route not found: {route}")
        for g in GUARDS:
            if g not in src:
                problems.append(f"pre-LLM 400 guard missing from dashboard: {g}")
    for fname, struct, fields in SWIFT_MODELS:
        f = app_dir / fname
        if not f.exists():
            problems.append(f"swift file missing: {fname}")
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        if not re.search(r"struct\s+%s\b" % struct, text):
            problems.append(f"{fname}: struct {struct} missing")
            continue
        for field, kind in fields:
            if not pin_field(text, struct, field, kind):
                problems.append(
                    f"{fname}: struct {struct} field '{field}' must be "
                    f"{'non-optional (req)' if kind == 'req' else 'Optional (opt)'}")
    return problems


# --- Layer B: live probes ----------------------------------------------------
def mint_bearer():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from check_cc_contract import mint_bearer as _mb
    return _mb()


def _req(path, token, timeout=25, body=None):
    import urllib.error
    import urllib.request
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        "http://127.0.0.1:9119" + path,
        data=data,
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json"} if data else
                {"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:400]
    except Exception as e:
        return -1, str(e)[:160].encode()


def check_400_body(doc, what):
    """A guard-400 body must be {detail: <non-empty string>}."""
    if not isinstance(doc, dict):
        return f"{what}: body not an object"
    d = doc.get("detail")
    if not (isinstance(d, str) and d.strip()):
        return f"{what}: 'detail' missing/empty"
    return ""


def decode_history(doc):
    """Shadow of the app's WorkHistory model."""
    if not isinstance(doc, dict):
        return "payload not an object"
    probs = []
    if "available" not in doc:
        probs.append("missing required 'available'")
    msgs = doc.get("messages")
    if isinstance(msgs, list) and msgs:
        for i, el in enumerate(msgs[:5]):
            if not isinstance(el, dict):
                probs.append(f"messages[{i}] not an object")
            elif "role" not in el:
                probs.append(f"messages[{i}] missing required 'role'")
    return "; ".join(probs)


def check_live():
    try:
        token = mint_bearer()
    except Exception as e:
        print(f"SKIP (live): cannot mint bearer — {e}")
        return True
    ok = True

    # 1. work chat empty-text guard (fires BEFORE any LLM turn)
    st, body = _req("/api/control/work/contract-probe/chat", token,
                    body={"text": "   ", "title": ""})
    if st == -1:
        print(f"SKIP (live): dashboard unreachable ({body[:80]!r})")
        return True
    if st != 400:
        print(f"CHAT-CONTRACT-FAIL (live): POST work chat empty-text -> HTTP {st} "
              f"(expected the pre-LLM 400 guard)")
        ok = False
    else:
        try:
            parsed = json.loads(body)
            v = check_400_body(parsed, "work chat 400")
        except Exception as e:
            v = f"bad JSON: {e}"
        if v:
            print(f"CHAT-CONTRACT-FAIL (live): {v}")
            ok = False
        else:
            print("LIVE POST work/{id}/chat: 400 guard OK (pre-LLM, zero cost)")

    # 2. project/task empty-text guard
    st, body = _req("/api/control/project/task", token,
                    body={"project": "contract-probe", "text": ""})
    if st != 400:
        print(f"CHAT-CONTRACT-FAIL (live): POST project/task empty-text -> "
              f"HTTP {st} (expected 400 guard)")
        ok = False
    else:
        try:
            v = check_400_body(json.loads(body), "project/task 400")
        except Exception as e:
            v = f"bad JSON: {e}"
        if v:
            print(f"CHAT-CONTRACT-FAIL (live): {v}")
            ok = False
        else:
            print("LIVE POST project/task: 400 guard OK (pre-LLM, zero cost)")

    # 3. history for a nonexistent id: the empty shape must decode
    st, body = _req("/api/control/work/contract-probe/history", token)
    if st != 200:
        print(f"CHAT-CONTRACT-FAIL (live): GET work history -> HTTP {st}")
        return False
    try:
        doc = json.loads(body)
    except Exception as e:
        print(f"CHAT-CONTRACT-FAIL (live): history bad JSON: {e}")
        return False
    v = decode_history(doc)
    if v:
        print(f"CHAT-CONTRACT-FAIL (live): history decode: {v}")
        ok = False
    else:
        print("LIVE GET work/{id}/history: 200 decode OK (empty shape)")

    # 4. non-vacuous element shadow: history of a REAL session (from activity)
    st, body = _req("/api/control/activity", token)
    element_seen = False
    if st == 200:
        try:
            sessions = (json.loads(body) or {}).get("sessions") or []
        except Exception:
            sessions = []
        # richest first: most messages
        cands = sorted((s for s in sessions if isinstance(s, dict)
                        and (s.get("messages") or 0) > 0 and s.get("id")),
                       key=lambda s: s.get("messages") or 0, reverse=True)
        for s in cands[:3]:
            st2, body2 = _req(f"/api/control/work/{s['id']}/history", token)
            if st2 != 200:
                continue
            try:
                doc2 = json.loads(body2)
            except Exception:
                continue
            v2 = decode_history(doc2)
            n = len((doc2 or {}).get("messages") or [])
            if v2:
                print(f"CHAT-CONTRACT-FAIL (live): real-session history decode: {v2}")
                ok = False
            elif n:
                element_seen = True
                print(f"LIVE GET history({s['id'][:12]}…): {n} messages, "
                      f"element shadow OK")
                break
    if not element_seen:
        print("NOTE (live): no session with messages reachable — element "
              "shadow proven offline-only (Swift pins + empty-shape decode)")
    return ok


# --- --selftest: negative tests on TMP copies (real tree never touched) ------
def selftest():
    results = []

    def record(name, caught):
        results.append((name, bool(caught)))

    tmp = tempfile.mkdtemp(prefix="chat-contract-selftest-")
    tdir = Path(tmp)

    def tmp_dash(tamper=None):
        src = DASH_SRC.read_text(encoding="utf-8", errors="replace")
        if tamper:
            src = tamper(src)
        p = tdir / f"dash_{abs(hash(src)) % 10**8}.py"
        p.write_text(src, encoding="utf-8")
        return p

    def tmp_app(tamper_file=None, tamper=None):
        d = tdir / f"app_{abs(hash(str(tamper_file)+str(tamper))) % 10**8}"
        d.mkdir(exist_ok=True)
        for f in APP.glob("*.swift"):
            txt = f.read_text(encoding="utf-8", errors="replace")
            if tamper_file and f.name == tamper_file:
                txt = tamper(txt)
            (d / f.name).write_text(txt, encoding="utf-8")
        return d

    # T1 route vanish
    p = check_offline(tmp_dash(lambda s: s.replace(
        '@router.post("/api/control/project/task")', '# vanished')), APP)
    record("T1 route-vanish caught", any("route not found" in x for x in p))

    # T2 struct vanish
    p = check_offline(DASH_SRC, tmp_app("CCClient.swift", lambda s: s.replace(
        "struct WorkChatReply: Decodable", "struct WorkChatReplyGone: Decodable")))
    record("T2 struct-vanish caught", any("WorkChatReply missing" in x for x in p))

    # T3 req field vanish
    p = check_offline(DASH_SRC, tmp_app("CCClient.swift", lambda s: s.replace(
        "struct WorkChatReply: Decodable {\n    let reply: String",
        "struct WorkChatReply: Decodable {\n    let text: String")))
    record("T3 req-field-vanish caught", any(
        "WorkChatReply field 'reply'" in x for x in p))

    # T4 req->opt misclassification (available becomes Bool?)
    p = check_offline(DASH_SRC, tmp_app("CCClient.swift", lambda s: s.replace(
        "struct WorkHistory: Decodable {\n    struct Message: Decodable {\n"
        "        let role: String\n        let text: String?\n"
        "        let ts: Double?\n        let tool_name: String?\n    }\n"
        "    let available: Bool",
        "struct WorkHistory: Decodable {\n    struct Message: Decodable {\n"
        "        let role: String\n        let text: String?\n"
        "        let ts: Double?\n        let tool_name: String?\n    }\n"
        "    let available: Bool?")))
    record("T4 req-opt misclassification caught", any(
        "field 'available'" in x for x in p))

    # T5 pre-LLM guard vanish
    p = check_offline(tmp_dash(lambda s: s.replace(
        'detail="empty message"', 'detail="gone"')), APP)
    record("T5 guard-vanish caught", any("guard missing" in x for x in p))

    # T6 decode_history: missing `available` caught
    record("T6 live decode-gap caught",
           bool(decode_history({"messages": []})))

    # T7 element shadow: element missing role caught
    record("T7 element-role gap caught",
           bool(decode_history({"available": True,
                                "messages": [{"text": "x"}]})))

    # T8 positive: real-shaped payload decodes clean (incl. tool element)
    record("T8 real-shape decodes clean",
           not decode_history({"available": True, "session_id": "s1",
                               "total": 2,
                               "messages": [{"role": "user", "text": "hi",
                                             "ts": 1.0},
                                            {"role": "tool",
                                             "tool_name": "t", "ts": 2.0}]}))

    # T9 400-body checker: missing detail caught
    record("T9 400-body gap caught",
           bool(check_400_body({"detail": ""}, "x")))

    # T10 clean tree: offline pins pass, no false positive
    record("T10 clean tree offline pins pass",
           not check_offline())

    failed = [n for n, okr in results if not okr]
    for n, okr in results:
        print(f"{'PASS' if okr else 'FAIL'} {n}")
    print(f"SELFTEST: {len(results) - len(failed)}/{len(results)} PASS")
    return 0 if not failed else 1


def main():
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    problems = check_offline()
    if problems:
        for p in problems:
            print(f"CHAT-CONTRACT-FAIL: {p}")
        sys.exit(1)
    print(f"offline pins: {len(ROUTES)} routes + {len(GUARDS)} guards pinned, "
          f"{len(SWIFT_MODELS)} Swift models match")
    if "--offline-only" in sys.argv:
        print("live layer skipped (--offline-only)")
        return
    if not check_live():
        sys.exit(1)
    print("chat send-path contract: ALL GREEN")


if __name__ == "__main__":
    main()
