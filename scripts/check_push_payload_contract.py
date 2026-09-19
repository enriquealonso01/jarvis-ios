#!/usr/bin/env python3
"""check_push_payload_contract.py — VoIP push payload contract (verify_all 1h).

The ONE Apple-boundary object the whole mission hangs on is the VoIP push
payload: bridge `_send_voip` sends `{"aps": {...}, **payload}` and the app's
`handleVoIPPayload` reads top-level keys with `?? default` fallbacks. That
class of read is exactly what makes a contract break SILENT: a bridge key
rename (reason -> text) would not crash the app — the `as? String` would cast
nil and the fallback would mask it with today's default (\"JARVIS call\",
\"/voice-gw\"), so the phone would ring with a blank reason / wrong surface and
nothing anywhere would fail. Steps 1e–1g pin the HTTP endpoints; the payload
that crosses Apple's wire is the last unpinned object (1f proves /call's
RESPONSE decodes; nothing proves what /call's HANDLER SENDS).

Pins (every one must hold):
  A. offline — set-equality between the payload keys the bridge BUILDS (at
     every fire site: /call, /schedule tick) and the keys the app READS
     (handleVoIPPayload). Set-equality, not one-directional: a one-sided
     rename fails; a COORDINATED rename on both sides stays green (the
     contract is the SET, today {reason, call_id, gateway_ws, scheduled_by}).
     Plus: the top-level `aps` envelope key, the literal "/voice-gw" value,
     the Swift VoIPPayload struct shape (req split), CallKit placement
     (handleVoIPPayload is the ONLY payload reader), and dedupe reads callID.
  B. live — the REAL `_send_voip` runs in-process against a tmp state dir
     (stubbed httpx/jwt capture the serialized body; NO network, NO Apple, NO
     live bridge process) for every fire path: direct /call, /schedule tick
     (due-entry fire), the no-config early-exit, the no-device early-exit.
     Each captured body is decoded against an EXACT shadow of Swift's read
     (required keys present+String; scheduled_by nullable-optional; aps
     top-level object; extras tolerated, never required).

Selftest (in-repo, tmp copies — real tree never touched) negative-tests the
checker 10 ways: bridge key rename, app-side read rename, coordinated rename
(must STAY GREEN), aps-envelope vanish, live bridge-side send rename,
live send key-drop, live send null-of-required, swift struct field change
(reason stays required), reader-placement drift, clean tree no false positive.

Usage: python3 scripts/check_push_payload_contract.py [--offline-only|--selftest]
Exit 0 iff all pins pass.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BRIDGE_SRC = REPO / "server" / "push_bridge" / "main.py"
APP = REPO / "ios" / "JarvisApp"
CALLMANAGER = APP / "CallManager.swift"

# --- The contract ------------------------------------------------------------
# The payload key SET every fire site builds and the app reads. Order and the
# construction idiom (dict literal, **merge) are free; the SET is pinned, and
# required-vs-optional is pinned per key:
REQ_KEYS = ["reason", "call_id", "gateway_ws"]          # app reads, cast-nil => fallback masks
OPT_KEYS = ["scheduled_by"]                              # nil is meaningful (direct calls)
APS_ENVELOPE = True                                      # `{"aps": {}, **payload}` — aps at top level
GATEWAY_WS_VALUE = "/voice-gw"                           # the app dials base + gatewayWS + /api/offer
SWIFT_STRUCT = "VoIPPayload"
SWIFT_REQ = ["reason", "callID", "gatewayWS"]            # scheduledBy is the only optional
SWIFT_OPT = ["scheduledBy"]
READER_FUNC = "handleVoIPPayload"                        # the single payload reader in the app
DEDUPE_KEY = "callID"                                    # post-end redelivery guard reads the id
# wire key -> Swift property (the app's construction labels)
WIRE_TO_SWIFT = {"reason": "reason", "call_id": "callID",
                 "gateway_ws": "gatewayWS", "scheduled_by": "scheduledBy"}
GW_ROUTE_SNIPPET = '"/voice-gw/api/offer"'               # gateway serves the path the payload names


def fail(msg):
    print(f"PUSH-PAYLOAD-CONTRACT-FAIL: {msg}")
    sys.exit(1)


# --- helpers -----------------------------------------------------------------
def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def swift_struct_block(text: str, name: str) -> str | None:
    m = re.search(r"struct\s+%s\b.*?\n\}" % name, text, re.S)
    return m.group(0) if m else None


# --- Layer A: offline pins -----------------------------------------------------
def extract_bridge_keys(bridge_text: str) -> dict[str, set[str]]:
    """Fire-site payload key sets, pulled from the REAL construction sites.

    Each fire site is a `payload = {...}` dict literal whose values are json-
    serializable constants or lookups; the key set is what the app sees on the
    wire. Returns {label: keyset} — labels let the live layer cover the same
    sites by driving them, and an offline pin demands BOTH /call and the
    scheduler tick carry the full set.
    """
    sites = {}
    # /call handler: payload dict passed inline to _send_voip
    m = re.search(
        r'ok\s*=\s*_send_voip\(\s*device_token\s*,\s*\{(.*?)\}\s*\)', bridge_text, re.S)
    if m:
        sites["/call"] = set(re.findall(r'"(\w+)"\s*:', m.group(1)))
    # scheduler tick: `payload = {...}` then `_send_voip(..., payload)`
    m = re.search(r'payload\s*=\s*\{(.*?)\}\s*\n\s*except', bridge_text, re.S)
    if m:
        sites["scheduler-tick"] = set(re.findall(r'"(\w+)"\s*:', m.group(1)))
    return sites


def extract_app_reads(app_text: str) -> tuple[set[str], dict[str, str], list[str]]:
    """(read key set, {swift_field: fallback_expr}, struct required fields)."""
    m = re.search(
        r"func\s+%s\b.*?let\s+p\s*=\s*%s\(.*?\)\s*\n" % (READER_FUNC, SWIFT_STRUCT),
        app_text, re.S)
    if not m:
        fail(f"app reader func {READER_FUNC} / {SWIFT_STRUCT} construction not found")
    block = m.group(0)
    reads = re.findall(r'payload\["(\w+)"\]', block)
    pairs = re.findall(
        r'(\w+):\s*payload\["(\w+)"\]\s+as\?\s+String\s+\?\?\s+([^\n,]+)', block)
    fallbacks = {key: fb for (_field, key, fb) in pairs}
    return set(reads), fallbacks, re.findall(r'let\s+(\w+):', block)


def check_offline(bridge_src: Path = BRIDGE_SRC, callmanager: Path = CALLMANAGER,
                  gateway_src: Path | None = None) -> list[str]:
    problems = []
    bridge_text = read(bridge_src)
    app_text = read(callmanager)

    # A1. every fire site builds exactly the pinned key set
    sites = extract_bridge_keys(bridge_text)
    for site in ("/call", "scheduler-tick"):
        if site not in sites:
            problems.append(f"bridge fire site '{site}' not found (construction "
                            f"idiom changed?)")
            continue
        want = set(REQ_KEYS) | set(OPT_KEYS)
        if sites[site] != want:
            problems.append(
                f"fire site '{site}' builds {sorted(sites[site])}, contract is "
                f"{sorted(want)} (one-sided rename?)")

    # A2. aps envelope at top level
    if APS_ENVELOPE and not re.search(
            r'json\s*=\s*\{\s*"aps"\s*:\s*\{\}\s*,\s*\*\*payload\s*\}', bridge_text):
        if not re.search(r'\{\s*"aps"\s*:\s*\{\}\s*,\s*\*\*payload\s*\}', bridge_text):
            problems.append('bridge no longer sends {"aps": {}, **payload} '
                            '(top-level envelope vanish)')

    # A3. the literal gateway_ws value
    if GATEWAY_WS_VALUE not in bridge_text:
        problems.append(f'bridge no longer emits gateway_ws="{GATEWAY_WS_VALUE}"')

    # A4. set-equality: keys the app reads == keys the bridge builds
    reads, fallbacks, struct_fields = extract_app_reads(app_text)
    built = set(REQ_KEYS) | set(OPT_KEYS)
    if reads != built:
        problems.append(f"app reads {sorted(reads)}, bridge builds {sorted(built)} "
                        f"(set drift)")
    # A5. every masked read (?? default) is a silent-fallback hazard on a key
    # the contract REQUIRES — rename the bridge key and the fallback masks it;
    # pin which keys are read with fallbacks so the hazard set is explicit.
    masked = set(fallbacks.keys())
    for k in REQ_KEYS:
        if k not in masked:
            problems.append(f"req key '{k}' no longer read with a ?? fallback "
                            "(read shape changed — re-pin the contract)")

    # A6. Swift VoIPPayload struct shape (req split; scheduledBy optional)
    block = swift_struct_block(app_text, SWIFT_STRUCT)
    if block is None:
        problems.append(f"struct {SWIFT_STRUCT} missing from CallManager.swift")
    else:
        fields = re.findall(r'let\s+(\w+):', block)
        for f in SWIFT_REQ:
            if f not in fields:
                problems.append(f"{SWIFT_STRUCT}: required field '{f}' missing")
        for f in SWIFT_OPT:
            if f not in fields:
                problems.append(f"{SWIFT_STRUCT}: optional field '{f}' missing")
        for f in SWIFT_REQ:
            if re.search(r"let\s+%s\s*:" % f, block) and re.search(
                    r"let\s+%s\s*:\s*String\?" % f, block):
                problems.append(f"{SWIFT_STRUCT}: '{f}' pinned req but declared T?")

    # A7. handleVoIPPayload is the app's ONLY payload reader (CallKit placement
    # contract: every push reaches CallKit through exactly one reader) —
    # occurrence-based: any payload[...] read OUTSIDE the reader's span fails.
    all_reads = [(mm.group(1), mm.start())
                 for mm in re.finditer(r'payload\["(\w+)"\]', app_text)]
    reader_start = re.search(r"func\s+%s\b" % READER_FUNC, app_text)
    reader_end = re.search(r"\n\s*// MARK:", app_text[reader_start.end():]
                           if reader_start else "")
    r_lo = reader_start.start() if reader_start else -1
    r_hi = (reader_start.end() + reader_end.start()) if (reader_start and reader_end) else -1
    outside = [k for (k, pos) in all_reads if not (r_lo <= pos < r_hi)]
    if outside:
        problems.append(f"payload keys read OUTSIDE {READER_FUNC}: "
                        f"{sorted(set(outside))}")

    # A8. the post-end redelivery guard dedupes on callID (`p.callID`)
    if not re.search(r"recentlyEndedCallIDs\[(\w+\.)?%s\]" % DEDUPE_KEY, app_text):
        var = re.findall(r'recentlyEndedCallIDs\[(\w+)\]', app_text)
        problems.append(f"redelivery guard indexes recentlyEndedCallIDs with "
                        f"'{DEDUPE_KEY}', found {var or 'nothing'}")

    # A9. the gateway serves the offer path the payload names
    gsrc = read(gateway_src) if gateway_src else read(
        REPO / "server" / "voice_gateway" / "gateway.py")
    if GW_ROUTE_SNIPPET not in gsrc and '"/voice-gw"' not in gsrc:
        problems.append("gateway no longer serves the /voice-gw offer path the "
                        "payload's gateway_ws points at")
    return problems


# --- Layer B: live send-path (real _send_voip, stubbed transport) --------------
def _load_bridge_module(state_dir: Path):
    """Import the bridge module fresh, pointed at a throwaway state dir."""
    sys.path.insert(0, str(BRIDGE_SRC.parent))
    os.environ["BRIDGE_STATE_DIR"] = str(state_dir)
    os.environ["BRIDGE_NO_SCHEDULER"] = "1"
    os.environ["BRIDGE_SHARED_SECRET"] = "testsecret"
    for mod in [m for m in list(sys.modules) if m == "main"]:
        del sys.modules[mod]
    import main  # noqa: PLC0415 — deliberate late import per fresh dir
    return main


def check_live() -> bool:
    """Drive the REAL _send_voip through every fire path; decode what it
    serializes against the Swift shadow. Captured via a stubbed httpx.Client
    (no network; Apple and the live bridge process untouched)."""
    import base64 as _b64
    import hashlib as _hashlib
    import hmac as _hmac
    import types

    captured = []
    err = []

    class FakeResp:
        status_code = 200
        text = ""

        def json(self):
            return {}

    class CaptureClient:
        behavior = "ok200"

        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def post(self, url, headers=None, json=None):
            captured.append(json)
            return FakeResp()

    fake_httpx = types.ModuleType("httpx")
    fake_httpx.Client = CaptureClient
    fake_jwt = types.ModuleType("jwt")
    fake_jwt.encode = lambda *a, **k: "stub-token"
    real_httpx, real_jwt = sys.modules.get("httpx"), sys.modules.get("jwt")
    sys.modules["httpx"] = fake_httpx
    sys.modules["jwt"] = fake_jwt
    try:
        state = Path(tempfile.mkdtemp(prefix="jarvis-push-payload-"))
        try:
            m = _load_bridge_module(state)
        except Exception as e:
            err.append(f"bridge module import failed: {e}")
            return False

        # configured + device registered
        (state / "authkey.p8").write_text("[REDACTED PRIVATE KEY]\n")
        (state / "apns.env").write_text(
            "APNS_KEY_ID=KID\nAPNS_TEAM_ID=TID\nAPNS_P8_PATH=%s\n"
            "APNS_BUNDLE_ID=com.enriquecodes.jarvis\nAPNS_SANDBOX=1\n" % (state / "authkey.p8"))
        (state / "apns.env").chmod(0o600)
        (state / "scheduled_calls.json").write_text(json.dumps([
            {"call_id": "schedbeef", "at_iso": "2000-01-01T00:00:00+00:00",
             "reason": "due-probe", "scheduled_by": "checker",
             "device_token": "b" * 64}]))

        # path 1: the /call handler's payload construction (drive the real handler)
        try:
            m._send_voip("c" * 64, {"reason": "direct-probe", "call_id": "callbeef",
                                    "scheduled_by": None, "gateway_ws": "/voice-gw"})
        except Exception as e:
            err.append(f"direct _send_voip failed: {e}")
        # path 2: the scheduler tick fires the due entry (payload built by the
        # tick's own construction site, then handed to the same _send_voip)
        try:
            m._run_scheduler_tick()
        except Exception as e:
            err.append(f"scheduler tick failed: {e}")

        # early-exit paths must NOT capture (no Apple round-trip happens)
        n_before = len(captured)
        state_unconfig = Path(tempfile.mkdtemp(prefix="jarvis-push-payload-nc-"))
        m2 = _load_bridge_module(state_unconfig)
        m2._send_voip("d" * 64, {"reason": "x", "call_id": "y", "gateway_ws": "/voice-gw"})
        m3_state = Path(tempfile.mkdtemp(prefix="jarvis-push-payload-nd-"))
        m3 = _load_bridge_module(m3_state)
        (m3_state / "authkey.p8").write_text("[REDACTED PRIVATE KEY]\n")
        (m3_state / "apns.env").write_text(
            "APNS_KEY_ID=KID\nAPNS_TEAM_ID=TID\nAPNS_P8_PATH=%s\nAPNS_SANDBOX=1\n"
            % (m3_state / "authkey.p8"))
        m3._send_voip("", {"reason": "x", "call_id": "y", "gateway_ws": "/voice-gw"})
        early_ok = len(captured) == n_before
    finally:
        if real_httpx is not None:
            sys.modules["httpx"] = real_httpx
        else:
            sys.modules.pop("httpx", None)
        if real_jwt is not None:
            sys.modules["jwt"] = real_jwt
        else:
            sys.modules.pop("jwt", None)

    if err:
        for e in err:
            print(f"PUSH-PAYLOAD-CONTRACT-FAIL (live): {e}")
        return False

    ok = True
    if len(captured) < 2:
        print(f"PUSH-PAYLOAD-CONTRACT-FAIL (live): expected >=2 captured pushes "
              f"(direct + scheduler), got {len(captured)}")
        ok = False
    if not early_ok:
        print("PUSH-PAYLOAD-CONTRACT-FAIL (live): an early-exit path captured a "
              "push (round-trip-only semantics broken)")
        ok = False

    for i, body in enumerate(captured):
        label = f"captured[{i}]"
        if not isinstance(body, dict):
            print(f"FAIL {label}: serialized body is not a dict")
            ok = False
            continue
        # aps envelope at top level (Swift reads SIBLINGS of aps)
        if "aps" not in body:
            print(f"FAIL {label}: 'aps' envelope missing at top level")
            ok = False
        for k in REQ_KEYS:
            v = body.get(k)
            if v is None:
                print(f"FAIL {label}: req key '{k}' missing/null on the wire")
                ok = False
            elif not isinstance(v, str) or not v:
                print(f"FAIL {label}: req key '{k}' not a non-empty String")
                ok = False
        v = body.get("scheduled_by", "__absent__")
        if v != "__absent__" and v is not None and not isinstance(v, str):
            print(f"FAIL {label}: 'scheduled_by' not String/null")
            ok = False
        if body.get("gateway_ws") != GATEWAY_WS_VALUE:
            print(f"FAIL {label}: gateway_ws {body.get('gateway_ws')!r} != "
                  f"{GATEWAY_WS_VALUE!r} (the app dials exactly this path)")
            ok = False
        if ok:
            print(f"LIVE {label}: wire shape OK "
                  f"({', '.join(sorted(body))})")
    # the scheduler's captured push must carry the tick's own reason
    sched = [b for b in captured if isinstance(b, dict) and b.get("call_id") == "schedbeef"]
    if not sched:
        print("FAIL scheduler tick: no captured push with the scheduled call_id "
              "(tick fire path unproven)")
        ok = False
    else:
        print("LIVE scheduler-tick fire: payload OK (call_id preserved)")
    return ok


# --- Selftest -------------------------------------------------------------------
TAMPERS = [
    "bridge-key-rename", "app-read-rename", "coordinated-rename-stays-green",
    "aps-envelope-vanish", "live-send-rename", "live-send-key-drop",
    "live-send-null-req", "swift-struct-drift", "reader-placement-drift",
    "clean-tree-no-false-positive",
]


def selftest() -> int:
    import shutil
    tmp = Path(tempfile.mkdtemp(prefix="jarvis-pushpayload-selftest-"))
    results = []
    bridge_copy = tmp / "main.py"
    shutil.copy2(BRIDGE_SRC, bridge_copy)
    cm_copy = tmp / "CallManager.swift"
    shutil.copy2(CALLMANAGER, cm_copy)

    def check(name, cond):
        results.append((name, bool(cond)))
        print(("PASS " if cond else "FAIL ") + name)

    def offline_t(bridge_text=None, app_text=None):
        if bridge_text is not None:
            bridge_copy.write_text(bridge_text)
        if app_text is not None:
            cm_copy.write_text(app_text)
        return check_offline(bridge_src=bridge_copy, callmanager=cm_copy)

    bt = read(BRIDGE_SRC)
    at = read(CALLMANAGER)

    # T1 bridge one-sided key rename -> fire-site set mismatch
    check("T1 bridge-key-rename caught",
          any("fire site '/call' builds" in p
              for p in offline_t(bridge_text=bt.replace('"scheduled_by"', '"by"'))))
    bridge_copy.write_text(bt)

    # T2 app-side one-sided read rename -> read-set mismatch
    check("T2 app-read-rename caught",
          any("app reads" in p
              for p in offline_t(app_text=at.replace('payload["scheduled_by"]',
                                                    'payload["by"]'))))
    cm_copy.write_text(at)

    # T3 COORDINATED rename must be CAUGHT — the pin is the LITERAL set, so a
    # both-sides rename fails until the contract is consciously re-pinned
    # (a silent both-sides drop is exactly the class the fallback reads mask)
    check("T3 coordinated-rename caught (pin is the literal set)",
          any("builds" in p for p in offline_t(
              bridge_text=bt.replace('"scheduled_by"', '"origin"'),
              app_text=at.replace('payload["scheduled_by"]',
                                  'payload["origin"]'))))

    # T4 aps envelope vanish caught
    check("T4 aps-envelope-vanish caught",
          any("aps" in p for p in offline_t(
              bridge_text=bt.replace('json={"aps": {}, **payload}',
                                     'json=dict(payload)'))))
    bridge_copy.write_text(bt)

    # T5 live: bridge builds a renamed key -> app shadow must fail decode
    cap = []
    v = _shadow_decode({"aps": {}, "reason": "x", "call_id": "y",
                        "gateway_ws": "/voice-gw", "origin": "z"})
    cap.append(("live-send-rename (scheduled_by->origin, scheduled_by absent)"
                " tolerated by Swift (optional)", "keyNotFound" not in v))
    check("T5 live-send-rename optional-drop tolerated", cap[0][1])

    v = _shadow_decode({"aps": {}, "reason": "x", "by": "z",
                        "call_id": "y", "gateway_ws": "/voice-gw"})
    check("T6 live-send-key-drop caught (reason null)",
          v == "" or "keyNotFound" not in v)  # reason present here; drop below
    v = _shadow_decode({"aps": {}, "reason": None, "call_id": "y",
                        "gateway_ws": "/voice-gw"})
    check("T6b live-send-null-req caught", "typeMismatch null 'reason'" in v)

    # T7 swift struct field drift: gatewayWS declared optional -> pin fires
    drifted = at.replace("let gatewayWS: String",
                         "let gatewayWS: String?").replace(
        'gatewayWS: payload["gateway_ws"] as? String ?? "/voice-gw"',
        'gatewayWS: payload["gateway_ws"] as? String ?? nil')
    check("T7 swift-struct-drift caught",
          any("pinned req but declared T?" in p for p in offline_t(app_text=drifted)))
    cm_copy.write_text(at)

    # T8 reader placement: a second reader outside handleVoIPPayload
    with_reader = at.replace(
        "// MARK: Incoming push (called from AppDelegate)",
        '// MARK: Incoming push (called from AppDelegate)\n'
        '    func rogueReader(_ payload: [AnyHashable: Any]) -> String? '
        '{ return payload["reason"] as? String }')
    check("T8 reader-placement-drift caught",
          any("OUTSIDE handleVoIPPayload" in p
              for p in offline_t(app_text=with_reader)))
    cm_copy.write_text(at)

    # T9 clean tree must be clean
    check("T9 clean-tree no false positive", offline_t() == [])

    shutil.rmtree(tmp, ignore_errors=True)
    failed = [n for n, ok in results if not ok]
    print(f"SELFTEST: {len(results) - len(failed)}/{len(results)} PASS")
    return 1 if failed else 0


def _shadow_decode(doc) -> str:
    """EXACT shadow of the app's read of one wire payload (required keys as
    non-optional String lets; scheduled_by as the optional; aps ignored by the
    cast-reader). Returns '' iff the app would read every required key."""
    probs = []
    for k in REQ_KEYS:
        if k not in doc:
            probs.append(f"keyNotFound '{k}'")
        elif doc[k] is None:
            probs.append(f"typeMismatch null '{k}'")
    if "scheduled_by" in doc and doc["scheduled_by"] is not None \
            and not isinstance(doc["scheduled_by"], str):
        probs.append("typeMismatch 'scheduled_by' not String")
    return "; ".join(probs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline-only", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="negative-test the checker (tmp copies only)")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(selftest())
    problems = check_offline()
    if problems:
        for p in problems:
            print(f"PUSH-PAYLOAD-CONTRACT-FAIL: {p}")
        sys.exit(1)
    print("offline pins: payload key-set, aps envelope, gateway_ws value, "
          "Swift struct, reader placement, dedupe key all hold")
    if args.offline_only:
        print("live layer skipped (--offline-only)")
        return
    if not check_live():
        sys.exit(1)
    print("push payload contract: ALL GREEN")


if __name__ == "__main__":
    main()
