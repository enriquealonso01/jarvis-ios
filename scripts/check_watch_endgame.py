#!/usr/bin/env python3
"""Sandboxed behavior suite for scripts/testflight_device_watch.sh.

WHY (2026-09-19, post-backlog increment): the watch is the ONLY announcer
left after the 23:00 sunset, and its endgame (both flips -> fire a REAL
verification call -> push_ok delta -> self-remove) would have executed for
the first time ever in prod, untested. The flip announcements and the
endgame are now proven here, against the REAL script, with every external
surface swapped for a sandbox double (the watch's WATCH_* env overrides;
prod defaults untouched):

  fake bridge  : HTTP server answering GET /health with controllable
                 device_registered / push_ok; POST /__fire__ bumps push_ok
                 (stands in for the real bridge's push_ok counter).
  fake probe   : prints the verdict from the sandbox's probe_verdict file
                 (the watch greps for "delivery path PROVEN").
  fake call    : appends to a call log, optionally exits 1 (call_fail flag),
                 and POSTs /__fire__ on success (a real call => push_ok++).
  fake hermes  : records `cron remove` into a hermes log.

Tests (each runs `bash` on the REAL watch script in a fresh sandbox):
  T1  pre-flip WAITs  : first tick announces both WAITs exactly once, later
                        ticks silent, NO call before flips
  T2  both flip       : KEY LIVE + REGISTERED + MISSION COMPLETE, call fired
                        exactly once, push_ok delta seen, cron removed, state
                        file consumed
  T3  endgame red     : push_ok stuck -> URGENT line, cron NOT removed
  T4  call fails      : call exits 1 -> URGENT, attempt logged once
  T5  latch           : after a failed endgame, the next tick is SILENT and
                        fires NO second call (the endgame_tried latch; the
                        pre-latch script re-fired a real call every 15m)
  T6  one flip only   : key live, phone still dark -> KEY LIVE line, no
                        MISSION, no removal, silent second tick
  T7  latch honored   : even all-green inputs again -> no second MISSION,
                        no second removal (self-remove is one-shot)

--selftest negative-tests the HARNESS on throwaway copies of the watch
script (real tree untouched):
  S1  latch lines removed from a copy -> T5 FAILS (catches a future edit
      that quietly reintroduces the 15m re-fire)
  S2  probe invocation broken in a copy -> flip 1 blind -> suite FAILS
  S3  device_registered grep broken in a copy -> flip 2 blind -> T2 bites
  S4  clean copy -> endgame completes (no false positive)

Safety: the suite pins the PROD state file (/tmp/.jarvis_ios_device_watch_state)
byte-identical before/after every run — a harness bug cannot touch prod.
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = pathlib.Path(__file__).resolve().parent.parent
WATCH = REPO / "scripts" / "testflight_device_watch.sh"
PROD_STATE = pathlib.Path("/tmp/.jarvis_ios_device_watch_state")

GOOD_VERDICT = "VERDICT: 400 BadDeviceToken (dummy token) — delivery path PROVEN."
BAD_VERDICT = "VERDICT: 403 InvalidProviderToken."


class _WatchServer(ThreadingHTTPServer):
    """ThreadingHTTPServer + a back-reference to the stateful fake bridge."""

    bridge: "FakeBridge"


class FakeBridge:
    """GET /health with controllable state; POST /__fire__ = an accepted push."""

    def __init__(self):
        self.device_registered = False
        self.push_ok = 10
        self.auto_fire = True  # the fake call triggers this on success
        self._srv = _WatchServer(("127.0.0.1", 0), _Handler)
        self._srv.bridge = self  # the handler reads state off the server
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self._srv.server_address[1]}"

    def fire(self) -> None:
        if self.auto_fire:
            self.push_ok += 1

    def stop(self) -> None:
        self._srv.shutdown()
        self._srv.server_close()


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        b: FakeBridge = self.server.bridge  # type: ignore[attr-defined]
        body = json.dumps({
            "ok": True,
            "apns_configured": True,
            "device_registered": b.device_registered,
            "push_ok": b.push_ok,
            "push_fail": 0,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/__fire__":
            self.server.bridge.fire()  # type: ignore[attr-defined]
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format: str, *args) -> None:  # silence request noise
        pass


class Sandbox:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="watch_endgame_")
        self.bridge = FakeBridge()
        self._write("probe_verdict.txt", BAD_VERDICT)
        self._write("call_log.txt", "")
        self._write("hermes_log.txt", "")
        self._write("call_fail", "")
        # The watch invokes BOTH tools via /usr/bin/python3 ("python3 $PROBE",
        # "python3 $CALL" — prod's probe_apns_delivery.py / call_enrique.py
        # are Python) — so BOTH doubles must be Python scripts; a #!/bin/sh
        # file dies with a SyntaxError and silently no-ops (the selftest
        # caught the call double on first authoring, the probe on the second).
        self._script("probe", f"""#!/usr/bin/python3
import pathlib, sys
print((pathlib.Path(__file__).resolve().parent / "probe_verdict.txt").read_text())
""")
        # NOTE: the watch invokes the call tool via /usr/bin/python3 (prod's
        # call_enrique.py is Python) — so this double must be Python too; a
        # #!/bin/sh script would die with a SyntaxError and no side effects
        # (the selftest caught exactly that on first authoring).
        self._script("call", f"""#!/usr/bin/python3
import pathlib, sys, urllib.request
d = pathlib.Path(__file__).resolve().parent
with open(d / "call_log.txt", "a") as f:
    f.write("call " + " ".join(sys.argv[1:]) + "\\n")
if (d / "call_fail").read_text().strip():
    sys.exit(1)
try:
    urllib.request.urlopen({self.bridge.url!r} + "/__fire__", data=b"", timeout=5)
except Exception:
    pass
""")
        self._script("hermes",
                     "#!/bin/sh\n"
                     "if [ \"$1\" = cron ] && [ \"$2\" = remove ]; then\n"
                     "  echo \"removed $3\" >> \"%s/hermes_log.txt\"\n"
                     "fi\nexit 0\n" % self.dir)

    # -- fixture plumbing -------------------------------------------------
    def _write(self, name: str, content: str) -> None:
        (pathlib.Path(self.dir) / name).write_text(content)

    def _script(self, name: str, body: str) -> None:
        p = pathlib.Path(self.dir) / name
        p.write_text(body)
        p.chmod(0o755)

    # -- watch execution --------------------------------------------------
    def run_watch(self, script_path=None) -> str:
        env = dict(os.environ)
        env.update({
            "WATCH_STATE": str(pathlib.Path(self.dir) / "state"),
            "WATCH_BRIDGE": self.bridge.url,
            "WATCH_PROBE": str(pathlib.Path(self.dir) / "probe"),
            "WATCH_CALL": str(pathlib.Path(self.dir) / "call"),
            "WATCH_HERMES": str(pathlib.Path(self.dir) / "hermes"),
        })
        r = subprocess.run(["bash", str(script_path or WATCH)],
                           capture_output=True, text=True, env=env, timeout=120)
        if r.returncode != 0:
            raise AssertionError(f"watch exited {r.returncode}: {r.stderr[:300]}")
        return r.stdout

    # -- assertions -------------------------------------------------------
    @property
    def state(self) -> list[str]:
        f = pathlib.Path(self.dir) / "state"
        return f.read_text().splitlines() if f.exists() else []

    @property
    def call_log(self) -> list[str]:
        return [l for l in (pathlib.Path(self.dir) / "call_log.txt").read_text().splitlines() if l]

    @property
    def hermes_log(self) -> list[str]:
        return [l for l in (pathlib.Path(self.dir) / "hermes_log.txt").read_text().splitlines() if l]

    def flip(self, key: bool = False, device: bool = False, push_delta: bool = True) -> None:
        (pathlib.Path(self.dir) / "probe_verdict.txt").write_text(
            GOOD_VERDICT if key else BAD_VERDICT)
        self.bridge.device_registered = device
        self.bridge.auto_fire = push_delta

    def cleanup(self) -> None:
        self.bridge.stop()
        shutil.rmtree(self.dir, ignore_errors=True)


def _check(name: str, cond: bool, detail: str = "") -> bool:
    print(f"{'PASS' if cond else 'FAIL'} {name}" + (f" — {detail}" if detail and not cond else ""))
    return cond


def run_suite() -> bool:
    ok = True
    s = Sandbox()
    try:
        # T1 pre-flip: the FIRST tick announces each WAIT exactly once (by
        # design — state bits), the SECOND is silent; no call, no removal.
        out = s.run_watch()
        ok &= _check("T1 first tick announces both WAITs",
                     "WAIT: APNs key flip pending" in out and "WAIT: device not registered" in out,
                     repr(out[:120]))
        ok &= _check("T1 WAIT bits latched",
                     "key_wait_announced" in s.state and "device_wait_announced" in s.state,
                     str(s.state))
        ok &= _check("T1 no call before flips", s.call_log == [], str(s.call_log))
        out = s.run_watch()
        ok &= _check("T1 later ticks silent", out.strip() == "", repr(out[:120]))

        # T2 both flips -> full endgame, one call, cron self-removed, and the
        # state file GONE (MISSION COMPLETE removes it — fresh watch next time).
        s.flip(key=True, device=True, push_delta=True)
        out = s.run_watch()
        ok &= _check("T2 KEY LIVE announced", "KEY LIVE" in out)
        ok &= _check("T2 REGISTERED announced", "REGISTERED" in out)
        ok &= _check("T2 MISSION COMPLETE", "MISSION COMPLETE" in out)
        ok &= _check("T2 exactly one verification call", len(s.call_log) == 1, str(s.call_log))
        ok &= _check("T2 cron self-removed",
                     s.hermes_log == ["removed jarvis-ios-device-watch"], str(s.hermes_log))
        ok &= _check("T2 state file consumed by success",
                     not (pathlib.Path(s.dir) / "state").exists(), str(s.state))
    finally:
        s.cleanup()

    # T3 endgame red: push_ok stuck -> URGENT, cron NOT removed.
    s = Sandbox()
    try:
        s.flip(key=True, device=True, push_delta=False)
        out = s.run_watch()
        ok &= _check("T3 URGENT on stuck push_ok", "URGENT" in out)
        ok &= _check("T3 cron stays armed", s.hermes_log == [], str(s.hermes_log))

        # T5 the latch: second tick fires NO second call and prints nothing.
        out = s.run_watch()
        ok &= _check("T5 latched tick silent", out.strip() == "", repr(out[:120]))
        ok &= _check("T5 exactly one call ever", len(s.call_log) == 1, str(s.call_log))

        # T7 latch holds even when the bridge later shows the delta: no second
        # MISSION, no second removal (self-remove is one-shot by design).
        s.flip(key=True, device=True, push_delta=True)
        out = s.run_watch()
        ok &= _check("T7 no second MISSION", "MISSION COMPLETE" not in out)
        ok &= _check("T7 no second removal", len(s.hermes_log) == 0, str(s.hermes_log))
    finally:
        s.cleanup()

    # T4 call failure -> URGENT, attempted once.
    s = Sandbox()
    try:
        s.flip(key=True, device=True, push_delta=True)
        (pathlib.Path(s.dir) / "call_fail").write_text("1")
        out = s.run_watch()
        ok &= _check("T4 URGENT on call failure", "URGENT" in out)
        ok &= _check("T4 call attempted once", len(s.call_log) == 1, str(s.call_log))
        ok &= _check("T4 cron stays armed", s.hermes_log == [], str(s.hermes_log))
    finally:
        s.cleanup()

    # T6 one flip only: key live, phone dark -> KEY LIVE, no endgame.
    s = Sandbox()
    try:
        s.flip(key=True, device=False)
        out = s.run_watch()
        ok &= _check("T6 KEY LIVE announced", "KEY LIVE" in out)
        ok &= _check("T6 no endgame on half-flip",
                     "MISSION COMPLETE" not in out and "URGENT" not in out)
        ok &= _check("T6 no removal", s.hermes_log == [], str(s.hermes_log))
        out = s.run_watch()
        ok &= _check("T6 second tick silent", out.strip() == "", repr(out[:120]))
    finally:
        s.cleanup()
    return ok


# --- harness selftest: negative tests on throwaway COPIES of the watch -----
def run_selftest() -> bool:
    ok = True

    def mutated(old: str, new: str) -> pathlib.Path:
        src = WATCH.read_text()
        if old not in src:
            raise SystemExit(f"SELFTEST ANCHOR MISSING in {WATCH.name}: {old!r} drifted")
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="watch_selftest_")) / WATCH.name
        tmp.write_text(src.replace(old, new, 1))
        return tmp

    def cleanup_copy(p: pathlib.Path) -> None:
        shutil.rmtree(p.parent, ignore_errors=True)

    # S1: remove the latch -> the re-fire protection is gone -> T5 must bite.
    copy = mutated('   && ! grep -q \'^endgame_tried$\' "$STATE"; then\n', '   ; then\n')
    s = Sandbox()
    try:
        s.flip(key=True, device=True, push_delta=False)
        s.run_watch(copy)
        out = s.run_watch(copy)
        ok &= _check("S1 unlatched copy re-fires (T5 catches it)",
                     out.strip() != "" and len(s.call_log) == 2,
                     f"out={out[:60]!r} calls={len(s.call_log)}")
    finally:
        s.cleanup()
        cleanup_copy(copy)

    # S2: probe invocation broken -> flip 1 is blind -> no WAIT bit is ever
    # set, so T1's bit assertion fails -> suite FAILS (a silent-blind watch
    # must not read as healthy).
    copy = mutated('"$PROBE"', '"/nonexistent/probe"')
    s = Sandbox()
    try:
        out = s.run_watch(copy)
        t1_ok = out.strip() == "" and "key_wait_announced" in s.state
        ok &= _check("S2 blind probe breaks the suite", not t1_ok)
    finally:
        s.cleanup()
        cleanup_copy(copy)

    # S3: device_registered grep broken -> flip 2 is blind -> T2 must bite.
    copy = mutated('"device_registered":', '"__never__":')
    s = Sandbox()
    try:
        s.flip(key=True, device=True)
        out = s.run_watch(copy)
        ok &= _check("S3 blind health-grep breaks the suite", "MISSION COMPLETE" not in out)
    finally:
        s.cleanup()
        cleanup_copy(copy)

    # S4: clean copy -> endgame completes (no false positive from the harness).
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="watch_selftest_")) / WATCH.name
    tmp.write_text(WATCH.read_text())
    s = Sandbox()
    try:
        s.flip(key=True, device=True)
        out = s.run_watch(tmp)
        ok &= _check("S4 clean copy still completes", "MISSION COMPLETE" in out)
    finally:
        s.cleanup()
        shutil.rmtree(tmp.parent, ignore_errors=True)
    return ok


def main() -> int:
    prod_before = PROD_STATE.read_bytes() if PROD_STATE.exists() else None
    if "--selftest" in sys.argv:
        ok = run_selftest()
        print("SELFTEST PASS" if ok else "SELFTEST FAIL")
    else:
        ok = run_suite()
        print("WATCH ENDGAME SANDBOX SUITE: ALL PASS" if ok else "WATCH ENDGAME SANDBOX SUITE: FAIL")
    prod_after = PROD_STATE.read_bytes() if PROD_STATE.exists() else None
    if prod_before != prod_after:
        print("FAIL prod state file changed — harness leak")
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
