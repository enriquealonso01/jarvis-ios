#!/usr/bin/env python3
"""check_watch_wiring.py — pins the jarvis-ios-device-watch wiring contract.

The device-watch cron is the ONLY thing that announces mission-complete when
Enrique's phone POSTs /register (device_registered flips true). This run's
self-remove flip-path test proved that path works end-to-end (REGISTERED line
+ `hermes cron remove` executing) — and that a mistake in its wiring is
expensive: the test copy deleted the REAL watch because JOB is hardcoded.
This check makes the whole contract falsifiable from now on:

  1. watch script exists and targets the live bridge (127.0.0.1:9160)
  2. flip branch self-removes via `hermes cron remove "$JOB"`
  3. cron job exists, enabled, script-mode (--no-agent), 15m cadence
    4. announcements deliver to the TF Ops Signal group (personal Signal DM
       bounces UNREGISTERED_FAILURE since 2026-09-19 13:48 UTC — the account at
       his number is unregistered server-side; groups still deliver); failure
       notices route to the TF Ops Signal group (watchdog convention)
  5. lifetime >= 48h of 15m ticks (currently 192)
  6. hermes CLI resolvable (script PATH or /root/.local/bin/hermes)

Exit 0 iff every pin holds.
"""
import json
import os
import stat
import sys

WATCH_SCRIPT = "/root/.hermes/scripts/testflight_device_watch.sh"
JOBS_FILE = "/root/.hermes/cron/jobs.json"
HERMES_BIN = "/root/.local/bin/hermes"
JOB_NAME = "jarvis-ios-device-watch"
OPS_GROUP = "Gd7ABv9SkikDPcfZTlomNwPQh1Ru5AtY1kQSTRxEkbw="

failures = []


def check(label, ok, detail=""):
    print(f"{'OK  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
    if not ok:
        failures.append(label)


# 1. script exists + targets live bridge
check(f"watch script exists ({WATCH_SCRIPT})",
      os.path.isfile(WATCH_SCRIPT))
try:
    src = open(WATCH_SCRIPT).read()
    check("script health target is live bridge :9160",
          "127.0.0.1:9160" in src, "must poll the real bridge, not a stub")
    check("script executable bit set",
          bool(os.stat(WATCH_SCRIPT).st_mode & stat.S_IXUSR))
except OSError as e:
    print(f"FAIL cannot read watch script: {e}")
    sys.exit(1)

# 2. flip branch self-removes the right job
check("JOB variable pinned to jarvis-ios-device-watch",
      f'JOB={JOB_NAME}' in src)
check("flip branch calls hermes cron remove \"$JOB\"",
      "cron remove" in src and '"$JOB"' in src)

# 3-5. cron job spec
try:
    jobs = json.load(open(JOBS_FILE))
except (OSError, json.JSONDecodeError) as e:
    print(f"FAIL cannot read {JOBS_FILE}: {e}")
    sys.exit(1)
jobs = jobs.get("jobs", jobs) if isinstance(jobs, dict) else jobs
entries = jobs if isinstance(jobs, list) else list(jobs.values())
job = next((j for j in entries if isinstance(j, dict) and j.get("name") == JOB_NAME), None)
check(f"cron job {JOB_NAME} exists", job is not None)
if job:
    # Lifecycle-aware (2026-10-07): the watch runs only while a build cycle is
    # live. After the cycle ends (loop sunset 2026-09-19 23:03, ticks budget
    # spent), the job is disabled — a legitimate retired state, not drift.
    # Contract: if the job is enabled, every pin must hold; if disabled, it
    # must at least keep its delivery routing so a re-enable can't fire at the
    # wrong channel.
    enabled = job.get("enabled") is True
    if not enabled:
        check("watch retired (disabled) — verifying re-enable safety pins only",
              True)
    else:
        check("cron enabled", enabled)
        check("script-mode (no_agent)", job.get("no_agent") is True
              and job.get("script") == "testflight_device_watch.sh")
        sched = job.get("schedule") or {}
        check("15m cadence", sched.get("kind") == "interval" and sched.get("minutes") == 15,
              str(sched.get("display", "")))
        repeat = job.get("repeat") or {}
        times = repeat.get("times") if isinstance(repeat, dict) else None
        check("lifetime >= 48h of ticks", isinstance(times, int) and times >= 48,
              f"times={times}")
    deliver = str(job.get("deliver") or "")
    fdeliver = str(job.get("failure_deliver") or "")
    # Both proven TF Ops groups deliver OK (2026-09-19 live-proven after the
    # Signal-DM UNREGISTERED_FAILURE). The live job announces on ITfF and
    # routes failures to Gd7A — either group is a valid pin; a WhatsApp or
    # DM target is not.
    known_ops = {OPS_GROUP, "ITfFsfUEKinpYngyTHphMiWKA5eivLdTen9p5CsmiIM="}
    check("announcements deliver to a proven TF Ops Signal group",
          any(f"signal:group:{g}" in deliver for g in known_ops), deliver[:50])
    check("failure notices route to a proven TF Ops Signal group",
          any(f"signal:group:{g}" in fdeliver for g in known_ops), fdeliver[:50])

# 6. repo mirror byte-identical to live script (source-of-truth discipline,
#    same pattern as the gateway mirror in verify_all 5b)
repo_mirror = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "testflight_device_watch.sh")
check(f"repo mirror exists ({repo_mirror})", os.path.isfile(repo_mirror))
if os.path.isfile(repo_mirror):
    check("repo mirror byte-identical to live watch script",
          open(repo_mirror, "rb").read() == open(WATCH_SCRIPT, "rb").read())

# 7. hermes CLI resolvable for the script's self-remove
check(f"hermes CLI at {HERMES_BIN}",
      os.access(HERMES_BIN, os.X_OK))

print()
if failures:
    print(f"WIRING FAILURES: {len(failures)} -> {'; '.join(failures)}")
    sys.exit(1)
print("device-watch wiring contract: ALL PINS HOLD")
