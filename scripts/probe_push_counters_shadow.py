#!/usr/bin/env python3
"""Shadow probe for the bridge's push-success counters (dev-observability).

Pins the dev-success-counter contract (PROGRESS 2026-09-19) against the REAL
module with a stubbed HTTP layer — no network, no live bridge touched:

  - every REAL Apple round-trip bumps exactly one counter
    (200 -> push_ok; transport error / HTTP error -> push_fail)
  - the no-config and no-device early-exits do NOT count (no round-trip)
  - a corrupt counters file resets, never crashes, still counts
  - /health exposes push_ok/push_fail as ints

Run:  python3 scripts/probe_push_counters_shadow.py
(verify_all step 1c runs it on every sweep)
"""
import json
import os
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server" / "push_bridge"))

results = []


def check(name, cond):
    results.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name)


class FakeResp:
    def __init__(self, status, reason=""):
        self.status_code = status
        self._reason = reason
        self.text = reason

    def json(self):
        return {"reason": self._reason}


class FakeClient:
    """Stub for httpx.Client used inside _send_voip (context manager + post)."""
    behavior = "ok200"  # tests set: "ok200" | "reject403" | "transport"

    def __init__(self, *a, **k):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def post(self, url, headers=None, json=None):
        if FakeClient.behavior == "transport":
            raise ConnectionError("simulated h2 handshake failure")
        if FakeClient.behavior == "reject403":
            return FakeResp(403, "InvalidProviderToken")
        return FakeResp(200)


def install_stubs():
    fake_httpx = types.ModuleType("httpx")
    fake_httpx.Client = FakeClient
    fake_jwt = types.ModuleType("jwt")
    fake_jwt.encode = lambda *a, **k: "stub-token"
    sys.modules["httpx"] = fake_httpx
    sys.modules["jwt"] = fake_jwt


def fresh_module(state_dir: Path):
    """(Re-)import the bridge module pointed at a throwaway state dir."""
    os.environ["BRIDGE_STATE_DIR"] = str(state_dir)
    os.environ["BRIDGE_NO_SCHEDULER"] = "1"
    os.environ["BRIDGE_SHARED_SECRET"] = "testsecret"
    for mod in [m for m in list(sys.modules) if m == "main"]:
        del sys.modules[mod]
    import main  # noqa: PLC0415 — deliberate late import per fresh dir
    return main


def write_env(state_dir: Path, configured=True, with_device=True):
    env = state_dir / "apns.env"
    p8 = state_dir / "authkey.p8"
    p8.write_text("-----BEGIN PRIVATE KEY-----\nstub\n-----END PRIVATE KEY-----\n")
    lines = []
    if configured:
        lines += [f"APNS_KEY_ID=ABC123TEST", "APNS_TEAM_ID=TEAM99",
                  f"APNS_P8_PATH={p8}", "APNS_SANDBOX=1"]
    if with_device:
        lines.append("DEVICE_TOKEN=" + "a" * 64)
    env.write_text("\n".join(lines) + "\n")


def counters(state_dir: Path):
    f = state_dir / "push_counters.json"
    return json.loads(f.read_text()) if f.exists() else {}


def main():
    install_stubs()
    payload = {"reason": "shadow", "call_id": "shadow1", "gateway_ws": "/voice-gw"}

    # -- real round-trips count, early-exits don't ------------------------
    d1 = Path(tempfile.mkdtemp(prefix="pushctr-ok-"))
    m = fresh_module(d1)
    write_env(d1)

    FakeClient.behavior = "transport"
    ok = m._send_voip("a" * 64, payload)
    check("transport error -> False", ok is False)
    check("transport error counted as push_fail", counters(d1).get("push_fail") == 1)

    FakeClient.behavior = "ok200"
    ok = m._send_voip("a" * 64, payload)
    check("HTTP 200 -> True", ok is True)
    check("HTTP 200 counted as push_ok", counters(d1).get("push_ok") == 1)
    check("push_fail unchanged by success", counters(d1).get("push_fail") == 1)

    FakeClient.behavior = "reject403"
    ok = m._send_voip("a" * 64, payload)
    check("HTTP 403 -> False", ok is False)
    check("HTTP 403 counted as push_fail", counters(d1).get("push_fail") == 2)

    # early-exit: unconfigured -> NOT counted
    write_env(d1, configured=False)
    ok = m._send_voip("a" * 64, payload)
    check("unconfigured early-exit -> False", ok is False)
    check("unconfigured early-exit NOT counted",
          counters(d1).get("push_fail") == 2 and counters(d1).get("push_ok") == 1)

    # early-exit: no device token -> NOT counted
    write_env(d1, with_device=False)
    ok = m._send_voip("", payload)
    check("no-device early-exit -> False", ok is False)
    check("no-device early-exit NOT counted",
          counters(d1).get("push_fail") == 2 and counters(d1).get("push_ok") == 1)

    # -- /health shape -----------------------------------------------------
    write_env(d1)
    h = m.health()
    check("/health exposes push_ok as int", isinstance(h.get("push_ok"), int) and h["push_ok"] == 1)
    check("/health exposes push_fail as int", isinstance(h.get("push_fail"), int) and h["push_fail"] == 2)
    check("/health still carries device_registered + last_push_error",
          "device_registered" in h and "last_push_error" in h)

    # -- corrupt counters file: reset, don't crash -------------------------
    d2 = Path(tempfile.mkdtemp(prefix="pushctr-bad-"))
    m2 = fresh_module(d2)
    write_env(d2)
    (d2 / "push_counters.json").write_text('{"broken": ')
    FakeClient.behavior = "ok200"
    ok = m2._send_voip("a" * 64, payload)
    check("corrupt counters file: push still succeeds", ok is True)
    check("corrupt counters file: counting restarts cleanly",
          counters(d2).get("push_ok") == 1 and "broken" not in counters(d2))

    # -- counters file perms (0600, same class as apns.env) ----------------
    mode = (d2 / "push_counters.json").stat().st_mode & 0o777
    check("counters file written 0600", mode == 0o600)

    print()
    bad = [n for n, ok_ in results if not ok_]
    if bad:
        print(f"{len(bad)} COUNTER PROBE FAILURE(S)")
        raise SystemExit(1)
    print(f"PUSH COUNTER SHADOW PROBE: {len(results)}/{len(results)} PASS")


if __name__ == "__main__":
    main()
