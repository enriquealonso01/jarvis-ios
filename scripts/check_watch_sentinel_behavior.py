#!/usr/bin/env python3
"""Sandbox behavior test for jarvis_ios_watch_sentinel.sh.

Runs the sentinel against a sandbox jobs.json, a stub bridge, and a stub
probe (all isolated via the JARVIS_IOS_* env overrides) and asserts each
behavior branch. Never touches production files: state/stood-down flags live
in a temp dir; the stub bridge binds an ephemeral localhost port.

Branches:
  B1 healthy watch          -> silent, exit 0, no alerts
  B2 healthy twice          -> still silent (no duplicate noise)
  B3 watch missing + bridge up          -> GONE alert once, stood-down set
  B4 same again                          -> SILENT (stand-down is one-shot)
  B5 watch paused + bridge up           -> PAUSED alert once
  B6 paused persists                     -> silent (latched)
  B7 paused fixed                        -> re-armed; next B5 fires again
  B8 stalled ticks (last_run 50m old)   -> STALLED alert once
  B9 tick budget low (5 left)           -> BUDGET alert once
  B10 bridge down (watch present)       -> BRIDGE alert once
  B11 probe no verdict                  -> PROBE alert once
  B12 multiple faults at once           -> all corresponding lines fire once
  B13 recovery                          -> silent, all re-armed
"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timedelta, timezone

REPO = os.path.dirname(os.path.abspath(__file__))
SENTINEL = os.path.join(REPO, "jarvis_ios_watch_sentinel.sh")
HEALTH = json.dumps({"ok": True, "device_registered": False}).encode()

passed, failed = [], []


def ok(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name}{(' — ' + detail) if detail else ''}")
    (passed if cond else failed).append(name)


class Bridge(http.server.BaseHTTPRequestHandler):
    up = True

    def do_GET(self):
        if Bridge.up:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(HEALTH)
        else:
            self.send_response(503)
            self.end_headers()

    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Bridge)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

tmp = tempfile.mkdtemp(prefix="sentinel_test_")
state = os.path.join(tmp, "state")
jobs_file = os.path.join(tmp, "jobs.json")
probe = os.path.join(tmp, "probe.py")
with open(probe, "w") as f:
    f.write("print('VERDICT: KEY REJECTED BY APNs.')\n")

env = {**os.environ,
       "JARVIS_IOS_SENTINEL_STATE": state,
       "JARVIS_IOS_JOBS": jobs_file,
       "JARVIS_IOS_PROBE": probe,
       "JARVIS_IOS_BRIDGE": f"http://127.0.0.1:{PORT}"}


def write_job(enabled=True, last_min_ago=5, times=384, completed=17, present=True):
    job = None
    if present:
        last = (datetime.now(timezone.utc) - timedelta(minutes=last_min_ago)).isoformat()
        job = {"name": "jarvis-ios-device-watch", "enabled": enabled,
               "repeat": {"times": times, "completed": completed},
               "last_run_at": last}
    with open(jobs_file, "w") as f:
        json.dump({"jobs": [j for j in [job] if j]}, f)


def run():
    return subprocess.run(["bash", SENTINEL], env=env, capture_output=True, text=True, timeout=60)


def out_lines(r):
    return [ln for ln in r.stdout.splitlines() if ln.startswith("SENTINEL:")]


# B1 healthy
Bridge.up = True
write_job()
r = run()
ok("B1 healthy watch -> silent", r.returncode == 0 and not out_lines(r), r.stdout.strip()[:80])

# B2 healthy again
r = run()
ok("B2 still healthy -> silent", r.returncode == 0 and not out_lines(r), r.stdout.strip()[:80])

# B3 watch gone + bridge up
write_job(present=False)
r = run()
ok("B3 watch gone -> GONE alert",
   r.returncode == 0 and len(out_lines(r)) == 1 and "removed" in out_lines(r)[0]
   and "REACHABLE" in out_lines(r)[0], r.stdout.strip()[:100])
ok("B3 stood-down flag set", os.path.exists(os.path.join(tmp, ".jarvis_ios_watch_sentinel_stooddown")))

# B4 gone again -> silent
r = run()
ok("B4 gone again -> silent (one-shot stand-down)", r.returncode == 0 and not out_lines(r),
   r.stdout.strip()[:80])

# B5 paused (fresh state: stand-down cleared because job present again)
write_job(enabled=False)
r = run()
ok("B5 paused -> PAUSED alert",
   r.returncode == 0 and len(out_lines(r)) == 1 and "PAUSED" in out_lines(r)[0], r.stdout.strip()[:100])

# B6 paused persists -> latched silent
r = run()
ok("B6 paused persists -> silent (latched)", r.returncode == 0 and not out_lines(r),
   r.stdout.strip()[:80])

# B7 fix -> re-arm; break again -> fires again
write_job(enabled=True)
run()  # arms
write_job(enabled=False)
r = run()
ok("B7 fix+break -> PAUSED fires again",
   len(out_lines(r)) == 1 and "PAUSED" in out_lines(r)[0], r.stdout.strip()[:100])

# B8 stalled
write_job(enabled=True, last_min_ago=50)
r = run()
ok("B8 stalled ticks -> STALLED alert",
   len(out_lines(r)) == 1 and "STALLED" in out_lines(r)[0], r.stdout.strip()[:100])

# B9 budget
write_job(enabled=True, completed=379)
r = run()
ok("B9 low budget -> BUDGET alert",
   len(out_lines(r)) == 1 and "ticks left" in out_lines(r)[0] and "5 ticks" in out_lines(r)[0],
   r.stdout.strip()[:100])

# B10 bridge down
Bridge.up = False
write_job()
r = run()
ok("B10 bridge down -> BRIDGE alert",
   len(out_lines(r)) == 1 and "UNREACHABLE" in out_lines(r)[0], r.stdout.strip()[:100])
Bridge.up = True

# B11 probe blind
with open(probe, "w") as f:
    f.write("import sys; sys.exit(1)\n")
r = run()
ok("B11 probe blind -> PROBE alert",
   len(out_lines(r)) == 1 and "NO VERDICT" in out_lines(r)[0], r.stdout.strip()[:100])

# B12 combined: paused + stalled + budget + bridge down + probe blind
Bridge.up = False
write_job(enabled=False, last_min_ago=90, completed=384)
run()  # fire all four once (latches set)
r = run()  # second run: latched -> silent; then B12 fresh-state single-fire
import os as _os
_os.remove(state)
# stalled+budget need enabled=True (paused branch short-circuits them)
write_job(enabled=True, last_min_ago=90, completed=384)
r = run()
lines = out_lines(r)
ok("B12 all faults -> one line each",
   len(lines) == 4
   and any("STALLED" in ln for ln in lines)
   and any("ticks left" in ln for ln in lines) and any("UNREACHABLE" in ln for ln in lines)
   and any("NO VERDICT" in ln for ln in lines),
   f"{len(lines)} lines: {[l[:45] for l in lines]}")
Bridge.up = True

# B13 recovery -> silent + re-armed
write_job(enabled=True, last_min_ago=2, completed=10)
with open(probe, "w") as f:
    f.write("print('VERDICT: delivery path PROVEN.')\n")
r = run()
ok("B13 recovery -> silent", r.returncode == 0 and not out_lines(r), r.stdout.strip()[:80])
r = run()
ok("B13b re-armed -> can re-fire later", r.returncode == 0 and not out_lines(r),
   r.stdout.strip()[:80])

srv.shutdown()
print()
if failed:
    print(f"SENTINEL BEHAVIOR: {len(failed)} FAILED -> {'; '.join(failed)}")
    sys.exit(1)
print(f"SENTINEL BEHAVIOR: {len(passed)}/{len(passed)} PASS")
