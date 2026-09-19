#!/usr/bin/env python3
"""check_watch_sentinel.py — pins the jarvis-ios-watch-sentinel contract.

The device-watch cron is the mission's ONLY autonomous flip announcer after
the build-loop sunset. The sentinel (30m, no-LLM) guards the guard: it alerts
the TF Ops group if the watch loses coverage. A broken or mis-wired sentinel
would be a silent false sense of safety, so its whole contract is pinned:

  1. sentinel script exists (repo + live ~/.hermes/scripts, executable)
  2. repo/live byte-identical
  3. cron jarvis-ios-watch-sentinel exists, enabled, no-agent script mode,
     30m cadence, generous tick budget
  4. announcements deliver to the TF Ops Signal group (guardian alerts are
     operator-facing, never user-facing); failure channel local-suppressed
     (the sentinel never exits non-zero by design)
  5. script pins: same JOB name as the watch, live bridge :9160, VERDICT
     probe, latched state file, no hermes mutations (observe-and-report only
     — it must never remove/pause/resume anything itself)
  6. repo mirror of the watch script still byte-identical to live
     (pre-existing contract, re-checked here because the sentinel reads the
     same job)
"""
import json
import os
import stat
import sys

REPO = os.path.dirname(os.path.abspath(__file__))
SENTINEL_REPO = os.path.join(REPO, "jarvis_ios_watch_sentinel.sh")
SENTINEL_LIVE = "/root/.hermes/scripts/jarvis_ios_watch_sentinel.sh"
WATCH_LIVE = "/root/.hermes/scripts/testflight_device_watch.sh"
WATCH_REPO = os.path.join(REPO, "testflight_device_watch.sh")
JOBS_FILE = "/root/.hermes/cron/jobs.json"
JOB_NAME = "jarvis-ios-watch-sentinel"
OPS_GROUP = "Gd7ABv9SkikDPcfZTlomNwPQh1Ru5AtY1kQSTRxEkbw="

failures = []


def check(label, ok, detail=""):
    print(f"{'OK  ' if ok else 'FAIL'} {label}{(' — ' + detail) if detail else ''}")
    if not ok:
        failures.append(label)


# 1-2. sentinel script present, executable, repo==live
check(f"sentinel script exists in repo ({SENTINEL_REPO})",
      os.path.isfile(SENTINEL_REPO))
check(f"sentinel script live ({SENTINEL_LIVE})",
      os.path.isfile(SENTINEL_LIVE))
if os.path.isfile(SENTINEL_REPO) and os.path.isfile(SENTINEL_LIVE):
    check("sentinel repo/live byte-identical",
          open(SENTINEL_REPO, "rb").read() == open(SENTINEL_LIVE, "rb").read())
    check("sentinel live executable bit set",
          bool(os.stat(SENTINEL_LIVE).st_mode & stat.S_IXUSR))

# 3-4. cron job spec
try:
    jobs = json.load(open(JOBS_FILE))
except (OSError, json.JSONDecodeError) as e:
    print(f"FAIL cannot read {JOBS_FILE}: {e}")
    sys.exit(1)
entries = jobs.get("jobs", jobs) if isinstance(jobs, dict) else jobs
entries = entries if isinstance(entries, list) else list(entries.values())
job = next((j for j in entries if isinstance(j, dict) and j.get("name") == JOB_NAME), None)
check(f"cron job {JOB_NAME} exists", job is not None)
if job:
    check("sentinel cron enabled", job.get("enabled") is True)
    check("sentinel script-mode (no_agent)",
          job.get("no_agent") is True and job.get("script") == "jarvis_ios_watch_sentinel.sh")
    sched = job.get("schedule") or {}
    check("30m cadence", sched.get("kind") == "interval" and sched.get("minutes") == 30,
          str(sched.get("display", "")))
    repeat = job.get("repeat") or {}
    times = repeat.get("times") if isinstance(repeat, dict) else None
    check("tick budget >= 480 (10 days of 30m)",
          isinstance(times, int) and times >= 480, f"times={times}")
    deliver = str(job.get("deliver") or "")
    fdeliver = str(job.get("failure_deliver") or "unset")
    check("alerts deliver to TF Ops group",
          deliver == f"signal:group:{OPS_GROUP}", deliver[:60])
    check("failure channel suppressed (never exits non-zero)",
          fdeliver == "local", fdeliver[:60])

# 5. script content pins
if os.path.isfile(SENTINEL_REPO):
    src = open(SENTINEL_REPO).read()
    check("guards the same job name as the device-watch",
          'JOB=jarvis-ios-device-watch' in src)
    check("health target is the live bridge :9160", "127.0.0.1:9160" in src)
    check("probe verdict check present", "grep -c '^VERDICT'" in src)
    check("alert latch state file present",
          "sentinel_alert_" in src and "STATE=" in src)
    check("no hermes invocations (observe-and-report only; the alert texts"
          " may MENTION 'hermes cron …' as human remediation, but the script"
          " must never define $HERMES or execute it)",
          "HERMES=" not in src and "$HERMES" not in src
          and "$(hermes" not in src and "`hermes" not in src)
    check("always exits 0", "exit 0" in src and "exit 1" not in src)
    check("GONE verdict is health-arbitrated (mission-complete self-remove"
          " with device_registered:true AND push_ok>=1 must stand down"
          " SILENTLY, never page as a loss)",
          "MISSION_DONE" in src and 'push_ok' in src
          and "QUIET stand-down" in src)

# 6. watch mirror contract still holds
if os.path.isfile(WATCH_REPO) and os.path.isfile(WATCH_LIVE):
    check("device-watch repo/live byte-identical",
          open(WATCH_REPO, "rb").read() == open(WATCH_LIVE, "rb").read())

print()
if failures:
    print(f"SENTINEL WIRING FAILURES: {len(failures)} -> {'; '.join(failures)}")
    sys.exit(1)
print("watch-sentinel contract: ALL PINS HOLD")
