"""Functional checks for backlog #4's server half: /call and /schedule now
accept the iOS app's dashboard Bearer token (dual auth, like /secrets) while
agents keep the x-bridge-sig HMAC path.

Run against a throwaway instance:
  BRIDGE_NO_SCHEDULER=1 BRIDGE_STATE_DIR=$(mktemp -d) \
  BRIDGE_SHARED_SECRET=testsecret uvicorn main:app --port 9162 &
  python3 scripts/probe_call_bearer_live.py --port 9162 --secret testsecret

The probe owns its listener: it spawns the uvicorn instance itself and ALWAYS
kills it on exit (orphaned instances from crashed runs caused a bind-conflict
incident — see PROGRESS 2026-09-19).
"""
import argparse
import atexit
import base64
import hashlib
import hmac
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import yaml

CFG = yaml.safe_load(open("/root/.hermes/config.yaml"))
raw = (CFG.get("dashboard") or {}).get("basic_auth", {}).get("secret", "")
secret_bytes = None
for dec in (base64.b64decode, bytes.fromhex):
    try:
        cand = dec(raw)
        if len(cand) >= 16:
            secret_bytes = cand
            break
    except Exception:
        pass
if secret_bytes is None:
    secret_bytes = raw.encode()


def mint_token(kind="access", ttl=600):
    payload = {"sub": "probe", "kind": kind, "exp": int(time.time()) + ttl}
    blob = json.dumps(payload, separators=(",", ":")).encode()
    sig = hmac.new(secret_bytes, blob, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(blob + sig).decode()


def sig_for(secret, body: bytes) -> str:
    return hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def req(base, method, path, headers=None, body=None):
    r = urllib.request.Request(base + path, method=method,
                               data=body,
                               headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=8) as resp:
            return resp.status, _as_json(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, _as_json(e.read())


def _as_json(raw: bytes):
    """Parse a response body as JSON; fall back to {"raw": ...} for non-JSON
    error pages (e.g. a bare 500 from a stale/misconfigured instance) so the
    probe reports FAIL instead of crashing with a JSONDecodeError."""
    try:
        return json.loads(raw or b"{}")
    except json.JSONDecodeError:
        return {"raw": (raw or b"").decode(errors="replace")[:200]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9162)
    ap.add_argument("--secret", default="testsecret")
    ap.add_argument("--spawn", action="store_true",
                    help="spawn (and always clean up) the throwaway uvicorn instance")
    a = ap.parse_args()
    base = f"http://127.0.0.1:{a.port}"
    token = mint_token()
    refresh = mint_token(kind="refresh")
    results = []

    proc = None
    if a.spawn:
        # Spawn the throwaway instance; guarantee cleanup even on crash/abort.
        state_dir = tempfile.mkdtemp(prefix="jarvis-probe-")
        env = dict(os.environ,
                   BRIDGE_NO_SCHEDULER="1",
                   BRIDGE_STATE_DIR=state_dir,
                   BRIDGE_SHARED_SECRET=a.secret)
        proc = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "main:app", "--port", str(a.port)],
            cwd=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                             "server", "push_bridge"),
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def _kill():
            if proc and proc.poll() is None:
                proc.kill()
                try:
                    proc.wait(timeout=5)
                except Exception:
                    pass
        atexit.register(_kill)
        signal.signal(signal.SIGTERM, lambda *_: (_kill(), sys.exit(143)))
        signal.signal(signal.SIGINT, lambda *_: (_kill(), sys.exit(130)))

        # Wait for /health to answer (up to ~15s).
        for _ in range(60):
            try:
                with urllib.request.urlopen(base + "/health", timeout=1) as r:
                    if r.status == 200:
                        break
            except Exception:
                time.sleep(0.25)
        else:
            print("FAIL test instance never became healthy")
            _kill()
            raise SystemExit(1)
        print(f"[probe] instance up on :{a.port} (state {state_dir})")

    def check(name, cond):
        results.append((name, bool(cond)))
        print(("PASS " if cond else "FAIL ") + name)

    good_body = json.dumps({"reason": "probe call", "scheduled_by": "probe"}).encode()

    # /schedule/list with bearer -> 200 (app path, added with backlog #4)
    st, _ = req(base, "GET", "/schedule/list", {"Authorization": f"Bearer {token}"})
    check("/schedule/list valid bearer 200", st == 200)

    # /call with valid bearer -> 200 (pushed False: no APNs on probe box)
    st, out = req(base, "POST", "/call", {"Authorization": f"Bearer {token}"}, good_body)
    check("/call valid bearer 200 + call_id", st == 200 and out.get("call_id"))
    call_id = out.get("call_id")

    # /call with invalid bearer -> 401
    st, _ = req(base, "POST", "/call", {"Authorization": "Bearer nope"}, good_body)
    check("/call bad bearer 401", st == 401)

    # /call with refresh-kind token -> 401
    st, _ = req(base, "POST", "/call", {"Authorization": f"Bearer {refresh}"}, good_body)
    check("/call refresh-kind 401", st == 401)

    # /call with NO auth -> 401 (dual ladder: neither path present)
    st, _ = req(base, "POST", "/call", {}, good_body)
    check("/call no auth 401", st == 401)

    # /call with classic HMAC sig still works (agents unaffected)
    st, out2 = req(base, "POST", "/call", {"x-bridge-sig": sig_for(a.secret, good_body)}, good_body)
    check("/call HMAC path still 200", st == 200 and out2.get("call_id"))

    # /schedule with bearer -> 200; list (HMAC) shows it
    sched_body = json.dumps({"at_iso": "2031-01-01T00:00:00+00:00", "reason": "probe sched"}).encode()
    st, out3 = req(base, "POST", "/schedule", {"Authorization": f"Bearer {token}"}, sched_body)
    check("/schedule valid bearer 200", st == 200 and out3.get("call_id"))
    sched_id = out3.get("call_id")

    # /schedule with bad bearer -> 401
    st, _ = req(base, "POST", "/schedule", {"Authorization": "Bearer x"}, sched_body)
    check("/schedule bad bearer 401", st == 401)

    # /schedule/list shows bearer-created entry, and must NOT leak the
    # snapshotted APNs device_token (or the internal failures counter) —
    # the token is a push-delivery secret; only the scheduler needs it.
    st, out4 = req(base, "GET", "/schedule/list", {"x-bridge-sig": sig_for(a.secret, b"")})
    entries = out4.get("scheduled", [])
    ids = [i["call_id"] for i in entries]
    check("/schedule/list shows bearer-created entry", st == 200 and sched_id in ids)
    check("/schedule/list strips device_token + failures",
          st == 200 and entries and
          all("device_token" not in i and "failures" not in i for i in entries))

    # cancel that entry via bearer
    cancel_body = json.dumps({"call_id": sched_id}).encode()
    st, out5 = req(base, "POST", "/schedule/cancel", {"Authorization": f"Bearer {token}"}, cancel_body)
    check("/schedule/cancel with bearer", st == 200 and out5.get("cancelled") == 1)

    # bad bearer on cancel -> 401
    st, _ = req(base, "POST", "/schedule/cancel", {"Authorization": "Bearer x"}, cancel_body)
    check("/schedule/cancel bad bearer 401", st == 401)

    # secrets endpoints unchanged sanity (bearer list)
    st, _ = req(base, "GET", "/secrets", {"Authorization": f"Bearer {token}"})
    check("/secrets bearer still 200", st == 200)

    # /register dual auth (app Bearer path added with the register fix): the app
    # cannot compute the agent HMAC, so launch-time token registration MUST work
    # over Bearer — otherwise no VoIP push can ever be delivered.
    reg_body = json.dumps({"device_token": "a" * 64, "bundle_id": "com.enriquecodes.jarvis"}).encode()
    st, out6 = req(base, "POST", "/register", {"Authorization": f"Bearer {token}"}, reg_body)
    check("/register valid bearer 200", st == 200 and out6.get("registered") is True)

    st, _ = req(base, "POST", "/register", {"Authorization": "Bearer nope"}, reg_body)
    check("/register bad bearer 401", st == 401)

    # agent HMAC path on /register still works and overwrites the token
    reg2 = json.dumps({"device_token": "b" * 64}).encode()
    st, out7 = req(base, "POST", "/register", {"x-bridge-sig": sig_for(a.secret, reg2)}, reg2)
    check("/register HMAC still 200", st == 200 and out7.get("token_len") == 64)


    bad = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(bad)}/{len(results)} passed")
    if bad:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
