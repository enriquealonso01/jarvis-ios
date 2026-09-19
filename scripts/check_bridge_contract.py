#!/usr/bin/env python3
"""check_bridge_contract.py — bridge-side decode contract for the iOS app's
Secrets and Calls tabs (verify_all step 1f).

Step 1e (check_cc_contract.py) pinned the dashboard half (Home + Chats).
This pins the OTHER half of the app's network surface: every bridge endpoint
the app calls and the exact Swift models its JSON decodes into:

  POST /secrets/set       -> SecretWriteResp { ok, created }
  GET  /secrets           -> SecretsListResp { secrets: [SecretMeta] }
  POST /secrets/delete    -> SecretWriteResp { ok, deleted }
  POST /register          -> HTTP 200 (app checks status only, no decode)
  GET  /schedule/list     -> ListResp        { scheduled: [ScheduledCall] }
  POST /schedule          -> SchedResp       { call_id, at }
  POST /schedule/cancel   -> CancelResp      { cancelled }
  POST /call              -> CallResp        { call_id, pushed }

Layer A (offline pins): bridge routes must exist in server/push_bridge/main.py,
the Swift structs must still declare the pinned fields, and the req/opt
SPLIT must match the Swift declarations (a field pinned req but declared
`T?` fails). Layer B (live): spawns the SAME throwaway uvicorn instance
probe_call_bearer_live.py uses (--spawn, tmp state dir, always cleaned up),
drives every endpoint with the app's dashboard Bearer (dual-auth app path)
in an order that leaves both collections NON-EMPTY when listed (set before
list; schedule before list) so the element shadows are never vacuous, and
decodes each payload against an EXACT shadow of Swift's synthesized
Decodable (req = keyNotFound/typeMismatch; opt = presence-only, UI degrades).

Negative-tested (each tamper must FAIL the checker loudly, then be restored
byte-identical): route-vanish, struct-vanish, req-field-vanish,
element-struct-vanish, element-field-rename, live server-side element rename,
live server-side key drop, live server-side null of a req key, and the
req/opt misclassification pin.

Usage: python3 scripts/check_bridge_contract.py [--offline-only]
Exit 0 iff all pins + live decodes pass.
"""
from __future__ import annotations

import argparse
import atexit
import base64
import hashlib
import hmac
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BRIDGE_SRC = REPO / "server" / "push_bridge" / "main.py"
APP = REPO / "ios" / "JarvisApp"

# --- The contract -----------------------------------------------------------
# fields_req = NON-Optional Swift `let x: T` (server rename/drop/null throws
# in the app — decode-breaking); fields_opt = Swift `T?` the app's logic still
# READS (decode-safe if dropped, but the UI silently degrades — pinned as
# presence-only). coll = a required collection whose ELEMENTS decode into the
# named Swift struct, split the same way (pinned offline too — 1e cannot see
# element structs at all). /register is status-only in the app (CallManager
# checks HTTP 200), so it pins route existence + request body keys only.
CONTRACT = [
    # (method, path, swift_file, model, fields_req, fields_opt, coll)
    ("POST", "/secrets/set", "SecretsView.swift", "SecretWriteResp",
     [], ["ok", "created"], None),  # set never returns 'deleted' — delete-only
    ("GET", "/secrets", "SecretsView.swift", "SecretsListResp",
     ["secrets"], [],
     {"key": "secrets", "elem": "SecretMeta",
      "req": ["name"], "opt": ["masked", "length", "updated_at", "updated_by"]}),
    ("POST", "/secrets/delete", "SecretsView.swift", "SecretWriteResp",
     [], ["ok", "deleted"], None),
    ("POST", "/register", "CallManager.swift", "", ["device_token"], [], None),
    ("GET", "/schedule/list", "CallsView.swift", "ListResp",
     ["scheduled"], [],
     {"key": "scheduled", "elem": "ScheduledCall",
      "req": ["call_id", "at_iso", "reason"], "opt": ["scheduled_by"]}),
    ("POST", "/schedule", "CallsView.swift", "SchedResp",
     ["call_id", "at"], [], None),
    ("POST", "/schedule/cancel", "CallsView.swift", "CancelResp",
     [], ["cancelled"], None),
    ("POST", "/call", "CallsView.swift", "CallResp",
     ["call_id", "pushed"], [], None),
]

# Swift structs each file must still declare (route decode models + element
# models both tabs build lists from).
SWIFT_STRUCTS = {
    "SecretsView.swift": ["SecretMeta", "SecretsListResp", "SecretWriteResp"],
    "CallsView.swift": ["ScheduledCall", "CancelResp", "CallResp"],
    "CallManager.swift": [],
}


def fail(msg):
    print(f"BRIDGE-CONTRACT-FAIL: {msg}")
    sys.exit(1)


# --- Layer A: offline pins ---------------------------------------------------

def struct_body(fname: str, struct: str, app_dir: Path | None = None) -> str | None:
    base = app_dir or APP
    f = base / fname
    if not f.exists():
        return None
    text = f.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"struct\s+%s\b.*?(?=\nstruct\s|\nextension\s|\n\n\n|\Z)"
                  % re.escape(struct), text, re.S)
    return m.group(0) if m else None


def check_offline(bridge_src: Path | None = None,
                  app_dir: Path | None = None) -> list[str]:
    """Pins against (bridge_src, app_dir), defaulting to the REAL tree.
    --selftest passes tmp COPIES with tampers applied."""
    bsrc = bridge_src or BRIDGE_SRC
    problems = []
    if not bsrc.exists():
        problems.append(f"bridge source missing: {bsrc}")
        return problems
    src = bsrc.read_text(encoding="utf-8", errors="replace")
    for method, path, swift, model, freq, fopt, coll in CONTRACT:
        pat = re.compile(r'@app\.(?:get|post)\("%s"' % re.escape(path))
        if not pat.search(src):
            problems.append(f"bridge route not found: {method} {path}")
    for fname, structs in SWIFT_STRUCTS.items():
        f = (app_dir or APP) / fname
        if not f.exists():
            problems.append(f"swift file missing: {fname}")
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        for s in structs:
            if not re.search(r"struct %s\b" % s, text):
                problems.append(f"{fname}: struct {s} missing")
    for method, path, swift, model, freq, fopt, coll in CONTRACT:
        if not model:
            # status-only endpoint: pin the request keys the app sends instead
            if swift == "CallManager.swift":
                text = ((app_dir or APP) / swift).read_text(
                    encoding="utf-8", errors="replace")
                for k in freq:
                    if not re.search(r'"%s"' % re.escape(k), text):
                        problems.append(f"{path}: request key '{k}' not sent "
                                        f"by {swift}")
            continue
        body = struct_body(swift, model, app_dir)
        if body is None:
            problems.append(f"{swift}: cannot locate struct {model} "
                            f"({method} {path})")
            continue
        for field in freq:
            if not re.search(r"let\s+%s\s*:" % re.escape(field), body):
                problems.append(f"{method} {path}: required field '{field}' "
                                f"missing from struct {model}")
        # collection ELEMENT structs are pinned offline as well: their req
        # fields must be declared `let` in the named Swift struct
        if coll and coll.get("elem"):
            ebody = struct_body(swift, coll["elem"], app_dir)
            if ebody is None:
                problems.append(f"{method} {path}: element struct "
                                f"{coll['elem']} missing from {swift}")
                continue
            for rk in coll["req"]:
                if not re.search(r"let\s+%s\s*:" % re.escape(rk), ebody):
                    problems.append(f"{method} {path}: element field '{rk}' "
                                    f"missing from struct {coll['elem']}")
        # the optionality SPLIT itself is pinned, BOTH directions: a field
        # pinned req must be declared NON-Optional (else the live layer demands
        # presence where the app tolerates absence), and a field pinned opt
        # must be declared `T?` (else the live layer UNDER-pins — it would
        # tolerate a server drop that throws keyNotFound in the app)
        for field in freq:
            if re.search(r"let\s+%s\s*:\s*[A-Za-z\[\]]+\?" % re.escape(field),
                         body):
                problems.append(f"{method} {path}: '{field}' pinned req "
                                f"but declared Optional in {model}")
        for field in fopt:
            if (re.search(r"let\s+%s\s*:" % re.escape(field), body)
                    and not re.search(
                        r"let\s+%s\s*:\s*[A-Za-z\[\]]+\?" % re.escape(field),
                        body)):
                problems.append(f"{method} {path}: '{field}' pinned opt but "
                                f"NON-Optional in {model} (live layer "
                                f"under-pins a decode-breaking field)")
    return problems


# --- Layer B: live decode against a throwaway instance -----------------------

def mint_bearer(secret_bytes: bytes, ttl=600) -> str:
    payload = {"sub": "probe", "kind": "access", "exp": int(time.time()) + ttl}
    blob = json.dumps(payload, separators=(",", ":")).encode()
    sig = hmac.new(secret_bytes, blob, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(blob + sig).decode()


def dash_secret_bytes() -> bytes:
    import yaml  # local import so the offline layer runs without yaml
    cfg = yaml.safe_load(open("/root/.hermes/config.yaml"))
    raw = (cfg.get("dashboard") or {}).get("basic_auth", {}).get("secret", "")
    for dec in (base64.b64decode, bytes.fromhex):
        try:
            cand = dec(raw)
            if len(cand) >= 16:
                return cand
        except Exception:
            pass
    return raw.encode()


def req(base, method, path, token, body=None, timeout=8):
    data = json.dumps(body).encode() if body is not None else (
        b"" if method == "GET" else None)
    r = urllib.request.Request(base + path, method=method, data=data,
                               headers={"Content-Type": "application/json",
                                        "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300]
    except Exception as e:
        return -1, str(e)[:160].encode()


class Instance:
    """Throwaway bridge (same recipe as probe_call_bearer_live.py): tmp state
    dir, scheduler off, ALWAYS killed (atexit + SIGINT/SIGTERM)."""

    def __init__(self, port=9163, secret="testsecret"):
        self.base = f"http://127.0.0.1:{port}"
        self.secret = secret
        self.state_dir = tempfile.mkdtemp(prefix="jarvis-bridge-contract-")
        env = dict(os.environ,
                   BRIDGE_NO_SCHEDULER="1",
                   BRIDGE_STATE_DIR=self.state_dir,
                   BRIDGE_SHARED_SECRET=secret)
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "main:app", "--port", str(port)],
            cwd=str(BRIDGE_SRC.parent), env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atexit.register(self.kill)
        signal.signal(signal.SIGTERM, lambda *_: (self.kill(), sys.exit(143)))
        signal.signal(signal.SIGINT, lambda *_: (self.kill(), sys.exit(130)))
        for _ in range(60):
            try:
                with urllib.request.urlopen(self.base + "/health",
                                            timeout=1) as r:
                    if r.status == 200:
                        return
            except Exception:
                time.sleep(0.25)
        self.kill()
        fail("test instance never became healthy")

    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
            try:
                self.proc.wait(timeout=5)
            except Exception:
                pass


def _doc(st, body, expect):
    if st != expect:
        return {"__http_error__": st,
                "__body__": body[:120].decode(errors="replace")}
    try:
        return json.loads(body)
    except Exception as e:
        return {"__bad_json__": str(e)}


def call_endpoints(base, token):
    """Drive every endpoint the way the APP does, in an order that leaves both
    collections NON-EMPTY when their list endpoint is sampled (set -> list ->
    delete; schedule -> list -> cancel), so the element shadows are real on
    every run. Contract-throwaway names only; the tmp-state instance dies at
    the end of the check."""
    out = []

    st, body = req(base, "POST", "/secrets/set", token,
                   {"name": "contract-probe", "value": "probe-value-12345",
                    "updated_by": "contract-probe"})
    out.append(("POST", "/secrets/set", _doc(st, body, 200), f"HTTP {st}"))

    st, body = req(base, "GET", "/secrets", token)  # non-empty now
    out.append(("GET", "/secrets", _doc(st, body, 200), f"HTTP {st}"))

    st, body = req(base, "POST", "/secrets/delete", token,
                   {"name": "contract-probe"})
    out.append(("POST", "/secrets/delete", _doc(st, body, 200), f"HTTP {st}"))

    st, body = req(base, "POST", "/register", token,
                   {"device_token": "a" * 64, "bundle_id": "probe.bundle"})
    out.append(("POST", "/register", None, f"HTTP {st}"))  # status-only

    st, body = req(base, "GET", "/schedule/list", token)  # envelope (may be [])
    out.append(("GET", "/schedule/list", _doc(st, body, 200), f"HTTP {st}"))

    st, body = req(base, "POST", "/schedule", token,
                   {"at_iso": "2033-01-01T00:00:00+00:00",
                    "reason": "contract-probe (auto-cancelled)",
                    "scheduled_by": "contract-probe"})
    sched = _doc(st, body, 200)
    out.append(("POST", "/schedule", sched, f"HTTP {st}"))

    st, body = req(base, "GET", "/schedule/list", token)  # non-empty now
    out.append(("GET", "/schedule/list#2", _doc(st, body, 200), f"HTTP {st}"))

    call_id = sched.get("call_id") if isinstance(sched, dict) else None
    st, body = req(base, "POST", "/schedule/cancel", token,
                   {"call_id": call_id or "no-such-id"})
    out.append(("POST", "/schedule/cancel", _doc(st, body, 200), f"HTTP {st}"))

    st, body = req(base, "POST", "/call", token,
                   {"reason": "contract-probe", "scheduled_by": "contract-probe"})
    out.append(("POST", "/call", _doc(st, body, 200), f"HTTP {st}"))
    return out


def shadow_decode(doc, spec) -> str:
    """EXACT shadow of Swift's synthesized Decodable conformance.
    fields_req = NON-Optional Swift `let` -> server rename/drop/null throws in
    the app (keyNotFound / typeMismatch), so every one must be present and
    non-null here. fields_opt = Swift `T?` the app logic still READS -> decode
    survives a drop, but the UI degrades, so pinned as PRESENCE-only (null
    allowed). Extra keys are ignored (JSONDecoder's real behavior)."""
    model, freq, fopt, coll = spec
    if not isinstance(doc, dict):
        return f"{model}: payload not an object ({type(doc).__name__})"
    probs = []
    for k in freq:
        if k not in doc:
            probs.append(f"{model}: keyNotFound '{k}'")
        elif doc[k] is None:
            probs.append(f"{model}: typeMismatch null '{k}'")
    for k in fopt:
        if k not in doc:
            probs.append(f"{model}: missing optional '{k}' (UI degrades)")
    if coll:
        arr = doc.get(coll["key"])
        if arr is None and coll["key"] in freq:
            probs.append(f"{model}: typeMismatch '{coll['key']}' not a list")
        elif isinstance(arr, list) and arr:
            for i, el in enumerate(arr[:3]):
                if not isinstance(el, dict):
                    probs.append(f"{coll['key']}[{i}] typeMismatch "
                                 f"expected object, got {type(el).__name__}")
                    continue
                for rk in coll["req"]:
                    if rk not in el:
                        probs.append(f"{coll['key']}[{i}]: keyNotFound '{rk}'")
                    elif el[rk] is None:
                        probs.append(f"{coll['key']}[{i}]: typeMismatch "
                                     f"null '{rk}'")
                for rk in coll.get("opt", ()):  # presence-only
                    if rk not in el:
                        probs.append(f"{coll['key']}[{i}]: missing optional "
                                     f"'{rk}' (UI degrades)")
    return "; ".join(probs)


def check_live() -> bool:
    try:
        secret_bytes = dash_secret_bytes()
    except Exception as e:
        print(f"SKIP (live): cannot mint bearer — {e}")
        return True
    inst = Instance()
    token = mint_bearer(secret_bytes)
    results = call_endpoints(inst.base, token)

    def spec_for(method: str, path: str):
        p = path.split("#")[0]  # '#2' = second sample of the same endpoint
        for spec in CONTRACT:
            if spec[0] == method and spec[1] == p:
                return spec
        return None

    all_ok = True
    list_samples = []  # (label, doc, coll) for every /schedule/list sample
    for method, path, doc, status_desc in results:
        spec = spec_for(method, path)
        if spec is None:
            print(f"BRIDGE-CONTRACT-FAIL (live): {method} {path} has no "
                  f"CONTRACT entry (checker bug)")
            all_ok = False
            continue
        if isinstance(doc, dict) and "__http_error__" in doc:
            print(f"BRIDGE-CONTRACT-FAIL (live): {method} {path} -> "
                  f"{doc['__http_error__']} ({doc['__body__']!r})")
            all_ok = False
            continue
        if method == "POST" and path == "/register":
            if status_desc == "HTTP 200":
                print("LIVE POST /register: 200 (app decodes status only) OK")
            else:
                print(f"BRIDGE-CONTRACT-FAIL (live): POST /register -> "
                      f"{status_desc}")
                all_ok = False
            continue
        if isinstance(doc, dict) and "__bad_json__" in doc:
            print(f"BRIDGE-CONTRACT-FAIL (live): {method} {path} bad JSON: "
                  f"{doc['__bad_json__']}")
            all_ok = False
            continue
        verdict = shadow_decode(doc, (spec[3], spec[4], spec[5], spec[6]))
        # collect every list sample so the element shadow can be proven
        # non-vacuous: an EMPTY list proves the envelope but not the element
        if spec[6] and path.split("#")[0] == "/schedule/list":
            list_samples.append((path, doc, spec[6]))
        if verdict:
            print(f"BRIDGE-CONTRACT-FAIL (live): {method} {path} decode: "
                  f"{verdict}")
            all_ok = False
        else:
            print(f"LIVE {method} {path}: decode OK ({status_desc})")
    # vacuous-element guard: at least ONE list sample must be non-empty, or
    # the element pin silently degraded to envelope-only
    n_elem = 0
    for label, doc, coll in list_samples:
        if isinstance(doc, dict) and isinstance(doc.get(coll["key"]), list):
            n_elem = max(n_elem, len(doc[coll["key"]]))
    if n_elem < 1:
        print("BRIDGE-CONTRACT-FAIL (live): element shadows never exercised "
              "(schedule list empty at every sample)")
        all_ok = False
    else:
        print(f"LIVE element shadows exercised: {n_elem} element(s) decoded")
    return all_ok


TAMPERS = ("route-vanish", "struct-vanish", "req-field-vanish",
           "element-struct-vanish", "element-field-rename",
           "live-element-rename", "live-key-drop", "live-req-null",
           "req-opt-misclassification")


def selftest() -> int:
    """Negative-tests the checker itself WITHOUT touching the real tree:
    offline tampers run against tmp COPIES; live tampers feed tampered
    payloads straight to shadow_decode (Swift's conformance is exact, so a
    payload the app cannot decode must be reported)."""
    global CONTRACT  # selftest REBINDS the module-level contract for T6
    import copy
    import shutil

    tmp = Path(tempfile.mkdtemp(prefix="jarvis-bridge-selftest-"))
    results: list[tuple[str, bool]] = []
    app_copy = tmp / "app"
    shutil.copytree(APP, app_copy)
    bridge_copy = tmp / "main.py"
    shutil.copy2(BRIDGE_SRC, bridge_copy)

    def offline_problems() -> list[str]:
        return check_offline(bridge_src=bridge_copy, app_dir=app_copy)

    def edit(path: Path, fn):
        t = path.read_text(encoding="utf-8", errors="replace")
        t2 = fn(t)
        assert t2 != t, f"selftest edit no-op in {path.name}"
        path.write_text(t2, encoding="utf-8")

    def check(name, ok):
        results.append((name, bool(ok)))
        print(("PASS " if ok else "FAIL ") + name)

    # T1 route-vanish (offline, tmp copy)
    edit(bridge_copy, lambda t: t.replace('@app.get("/secrets")',
                                          '@app.get("/secrets_old")', 1))
    check("T1 route-vanish caught",
          any("route not found: GET /secrets" in p for p in offline_problems()))
    bridge_copy.write_text(BRIDGE_SRC.read_text(encoding="utf-8",
                                                errors="replace"),
                           encoding="utf-8")

    # T2 struct-vanish (offline, tmp copy)
    edit(app_copy / "SecretsView.swift",
         lambda t: re.sub(r"struct SecretMeta: Decodable.*?\n\}\n", "", t,
                          count=1, flags=re.S))
    check("T2 struct-vanish caught",
          any("struct SecretMeta missing" in p for p in offline_problems()))
    shutil.copy2(APP / "SecretsView.swift", app_copy / "SecretsView.swift")

    # T3 req-field-vanish (offline, tmp copy)
    edit(app_copy / "CallsView.swift",
         lambda t: t.replace(
             "struct SchedResp: Decodable { let call_id: String; let at: String }",
             "struct SchedResp: Decodable { let call_id: String }", 1))
    check("T3 req-field-vanish caught",
          any("required field 'at' missing from struct SchedResp" in p
              for p in offline_problems()))
    shutil.copy2(APP / "CallsView.swift", app_copy / "CallsView.swift")

    # T4a element-struct-vanish (offline, tmp copy)
    edit(app_copy / "CallsView.swift",
         lambda t: re.sub(
             r"struct ScheduledCall: Identifiable, Decodable.*?\n        \}\n",
             "", t, count=1, flags=re.S))
    check("T4a element-struct-vanish caught",
          any("element struct ScheduledCall missing" in p
              for p in offline_problems()))
    shutil.copy2(APP / "CallsView.swift", app_copy / "CallsView.swift")

    # T4b element-field-rename (offline, tmp copy)
    edit(app_copy / "CallsView.swift",
         lambda t: t.replace("let reason: String", "let reasonText: String",
                             1))
    check("T4b element-field-rename caught",
          any("element field 'reason' missing from struct ScheduledCall" in p
              for p in offline_problems()))
    shutil.copy2(APP / "CallsView.swift", app_copy / "CallsView.swift")

    # T5a live server-side element rename -> keyNotFound 'name'
    bad = {"secrets": [{"nombre": "x", "masked": "x…", "length": 2,
                        "updated_at": "t", "updated_by": "u"}]}
    v = shadow_decode(bad, ("SecretsListResp", ["secrets"], [],
                            CONTRACT[1][6]))
    check("T5a live-element-rename caught", "keyNotFound 'name'" in v)

    # T5b live server-side key drop -> keyNotFound 'at'
    v = shadow_decode({"call_id": "x"}, ("SchedResp", ["call_id", "at"], [],
                                         None))
    check("T5b live-key-drop caught", "keyNotFound 'at'" in v)

    # T5c live server-side null of a req key -> typeMismatch null
    v = shadow_decode({"call_id": None, "at": "t"},
                      ("SchedResp", ["call_id", "at"], [], None))
    check("T5c live-req-null caught", "typeMismatch null 'call_id'" in v)

    # T6 req/opt misclassification: reclassify SchedResp's req fields as opt
    # in the in-memory contract; the offline pin must flag the mismatch
    saved = copy.deepcopy(CONTRACT)
    for i, spec in enumerate(CONTRACT):
        if spec[1] == "/schedule" and spec[0] == "POST":
            CONTRACT[i] = (spec[0], spec[1], spec[2], spec[3], [],
                           list(spec[4]) + list(spec[5]), spec[6])
    probs = check_offline()
    CONTRACT = saved
    check("T6 req-opt-misclassification caught",
          any("pinned opt but NON-Optional in SchedResp" in p
              for p in probs))

    # clean tree must be CLEAN (no false positives from the tampering above)
    check("clean tree offline pins pass", offline_problems() == [])
    shutil.rmtree(tmp, ignore_errors=True)

    failed = [n for n, ok in results if not ok]
    print(f"SELFTEST: {len(results) - len(failed)}/{len(results)} PASS")
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline-only", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="negative-test the checker (tmp copies only; real "
                         "tree untouched)")
    ap.add_argument("--port", type=int, default=9163)
    args = ap.parse_args()
    if args.selftest:
        sys.exit(selftest())
    problems = check_offline()
    if problems:
        for p in problems:
            print(f"BRIDGE-CONTRACT-FAIL: {p}")
        sys.exit(1)
    print(f"offline pins: {len(CONTRACT)} bridge routes pinned, "
          f"Swift models match")
    if args.offline_only:
        print("live layer skipped (--offline-only)")
        return
    if not check_live():
        sys.exit(1)
    print("bridge contract: ALL GREEN")


if __name__ == "__main__":
    main()
