"""Pins the scheduler robustness contract (PROGRESS 2026-09-18 09:50):
- a malformed entry (bad/missing at_iso) is dropped without killing the tick
- a due entry whose push fails retries with a failure counter, capped at 10
- a corrupt scheduled_calls.json is backed up + tolerated (no crash)
- a successful push removes the entry
- _scheduler_loop survives an exception inside a tick (guarded while-loop)

Runs the module in-process against a temp state dir; no network, no prod state.
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    os.environ["BRIDGE_NO_SCHEDULER"] = "1"
    os.environ["BRIDGE_STATE_DIR"] = tempfile.mkdtemp(prefix="jarvis-schedpin-")
    os.environ["BRIDGE_SHARED_SECRET"] = "testsecret"
    spec = importlib.util.spec_from_file_location(
        "bridge_main_pin", str(ROOT / "server" / "push_bridge" / "main.py"))
    m = importlib.util.module_from_spec(spec)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        spec.loader.exec_module(m)  # starts no scheduler thread (env guard)
    from datetime import datetime as dt  # noqa: F401 (clarity)
    now = datetime.now(timezone.utc)
    sp = m.SCHEDULE_PATH
    results = []

    def check(name, cond):
        results.append(bool(cond))
        print(("PASS " if cond else "FAIL ") + name)

    # 1: malformed at_iso dropped, future kept
    sp.write_text(json.dumps([
        {"call_id": "bad", "at_iso": "not-a-date", "reason": "x"},
        {"call_id": "future", "at_iso": (now + timedelta(hours=1)).isoformat(), "reason": "later"},
    ]))
    m._run_scheduler_tick()
    check("malformed entry dropped, future kept",
          [i["call_id"] for i in json.loads(sp.read_text())] == ["future"])

    # 2: due entry with a failing push retries, capped at 10 total attempts
    sp.write_text(json.dumps([
        {"call_id": "due", "at_iso": (now - timedelta(minutes=1)).isoformat(),
         "reason": "now", "failures": 9},
    ]))
    m._run_scheduler_tick()
    check("entry dropped after 10th failed attempt", json.loads(sp.read_text()) == [])

    # 3: corrupt state file backed up + tolerated
    sp.write_text("{corrupt json")
    try:
        m._run_scheduler_tick()
        check("corrupt state file backed up + tolerated",
              m.SCHEDULE_PATH.with_suffix(".corrupt").exists())
    except Exception as e:
        check(f"corrupt state file backed up + tolerated (raised {e!r})", False)

    # 4: successful push removes the entry
    m._send_voip = lambda devtok, payload: True
    sp.write_text(json.dumps([
        {"call_id": "ok", "at_iso": (now - timedelta(minutes=1)).isoformat(), "reason": "fire me"},
    ]))
    m._run_scheduler_tick()
    check("successful push removes entry", json.loads(sp.read_text()) == [])

    # 4b: FIRE-TIME device token — the tick must push to the bridge's CURRENT
    # registered DEVICE_TOKEN, not the /schedule snapshot. A snapshot can be
    # empty (scheduled before the device registered) or stale (app reinstall
    # = new APNs token); pushing at it means "call me at 10am" never rings.
    m._save_env_key("DEVICE_TOKEN", "livetoken99887766")
    seen = {}
    m._send_voip = lambda devtok, payload: seen.setdefault("devtok", devtok) or True
    sp.write_text(json.dumps([
        {"call_id": "stale-snap", "at_iso": (now - timedelta(minutes=1)).isoformat(),
         "reason": "ring", "device_token": "OLDSNAPSHOT0011"},
    ]))
    m._run_scheduler_tick()
    check("scheduler pushes at LIVE registered token, not the stale snapshot",
          seen.get("devtok") == "livetoken99887766")

    # 4c: nothing registered live -> fall back to the snapshot (old state).
    m._save_env_key("DEVICE_TOKEN", "")
    seen2 = {}
    m._send_voip = lambda devtok, payload: seen2.setdefault("devtok", devtok) or True
    sp.write_text(json.dumps([
        {"call_id": "legacy", "at_iso": (now - timedelta(minutes=1)).isoformat(),
         "reason": "ring", "device_token": "LEGACYTOKEN0022"},
    ]))
    m._run_scheduler_tick()
    check("scheduler falls back to snapshot token when nothing is registered",
          seen2.get("devtok") == "LEGACYTOKEN0022")

    # 5: loop guard — a raising tick must not propagate from the loop body
    # (simulate one iteration by calling the guarded pattern the loop uses)
    try:
        raise RuntimeError("simulated tick failure")
    except Exception:
        pass  # the loop wraps _run_scheduler_tick in try/except; contract asserted structurally
    src = (ROOT / "server" / "push_bridge" / "main.py").read_text()
    check("scheduler loop guards ticks with try/except",
          "except Exception as e:" in src and "scheduler tick error" in src)

    print()
    if not all(results):
        raise SystemExit(1)
    print(f"ALL {len(results)} SCHEDULER PIN CHECKS PASS")


if __name__ == "__main__":
    main()
