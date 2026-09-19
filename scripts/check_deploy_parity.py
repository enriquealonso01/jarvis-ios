#!/usr/bin/env python3
"""check_deploy_parity.py — pins the push-bridge DEPLOYMENT contract.

The bridge serves from the REPO checkout (systemd WorkingDirectory=
server/push_bridge): "a repo edit IS the deploy after a restart". Two copies
of the code exist outside the repo, and the contract has three teeth:

  1. the unit's WorkingDirectory points at THIS repo's push_bridge dir
  2. the unit's ExecStart runs uvicorn main:app from the bridge venv
  3. repo main.py exists and py_compiles (the restart gate)
  4. LKG rollback copy (/opt/jarvis-ios-bridge-lkg/main.py) is byte-identical
     to the repo — a stale LKG turns every "safe rollback" into a lie
  5. the RUNNING process proves it: live /health must carry `push_ok`, a
     field only the newest code exposes. A restarted-but-stale process
     (old working dir, stale .pyc shadowing) fails loudly here.
  6. state dir /opt/jarvis-ios-bridge holds shared_secret + apns.env

Why this exists (2026-09-19 ~15:30 UTC): /opt/jarvis-ios-bridge/main.py — a
setup-era copy, three feature-commits behind, loaded by NOTHING (unit runs
from the repo; live /health carried push_ok, which only the newest code has)
— cost a full run-audit chasing a "prod is stale" phantom that its own diff
created. It is gone (byte-identical to commit 40daafe, recoverable from git).
This check makes the whole deployment story falsifiable: repo == LKG ==
running process, or the sweep fails before anyone trusts a ghost.

--selftest synthesizes a FULLY tmp tree (no real path is read or written —
the check_watch_wiring.py "hardcoded JOB deleted the REAL watch" lesson);
negative-tests: stale LKG, wrong WorkingDirectory, broken py_compile,
missing WorkingDirectory.

Exit 0 iff every pin holds.
"""
import hashlib
import os
import py_compile
import sys
import tempfile
import urllib.request
from typing import Optional

REPO = "/root/projects/jarvis-ios/server/push_bridge/main.py"
REPO_DIR = "/root/projects/jarvis-ios/server/push_bridge"
LKG = "/opt/jarvis-ios-bridge-lkg/main.py"
UNIT = "/etc/systemd/system/jarvis-ios-bridge.service"
STATE_DIR = "/opt/jarvis-ios-bridge"
HEALTH_URL = "http://127.0.0.1:9160/health"

_failures = 0


def check(ok: bool, label: str, detail: str = "") -> bool:
    global _failures
    if ok:
        print(f"PASS {label}")
    else:
        _failures += 1
        print(f"FAIL {label}" + (f" — {detail}" if detail else ""))
    return ok


def sha256(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run(repo: str, lkg: str, unit: str, state_dir: str,
        health_url: Optional[str] = None) -> int:
    """One parity audit over the given paths. health_url=None skips the
    live-process pin (selftest has no bridge)."""
    fails_before = _failures

    # 1+2. unit pins
    try:
        unit_text = open(unit).read()
    except OSError as e:
        print(f"FAIL unit readable — {e}")
        return 1
    check(f"WorkingDirectory={os.path.dirname(repo)}" in unit_text,
          "unit WorkingDirectory -> repo push_bridge dir",
          "the bridge must serve from the repo checkout, not a copy")
    check("uvicorn main:app" in unit_text,
          "unit ExecStart runs uvicorn main:app",
          "the app object must come from the working dir's main.py")

    # 3. repo compiles
    try:
        py_compile.compile(repo, cfile=os.path.join(
            tempfile.mkdtemp(), "m.pyc"), doraise=True)
        check(True, "repo main.py py_compiles")
    except Exception as e:
        check(False, "repo main.py py_compiles", str(e)[:120])

    # 4. LKG rollback copy == repo
    try:
        check(sha256(lkg) == sha256(repo),
              "LKG rollback copy byte-identical to repo",
              f"{lkg} is STALE — refresh it from {repo} BEFORE the next "
              f"restart or the documented rollback path is a lie")
    except OSError as e:
        check(False, "LKG rollback copy byte-identical to repo",
              f"{lkg}: {e}")

    # 5. the RUNNING process proves currency (live only)
    if health_url:
        try:
            body = urllib.request.urlopen(health_url, timeout=5).read().decode()
            import json
            ok = json.loads(body).get("ok") is True
            check(ok and "push_ok" in body,
                  "live bridge /health answers ok:true with push_ok",
                  "running process does not expose the newest code's "
                  "capability marker — it is STALE or serving another copy")
        except Exception as e:
            check(False, "live bridge /health answers ok:true with push_ok",
                  str(e)[:120])

    # 6. state dir
    for name in ("shared_secret", "apns.env"):
        check(os.path.isfile(os.path.join(state_dir, name)),
              f"state file present: {name}")

    return 1 if _failures > fails_before else 0


def selftest() -> int:
    """Synthesized tmp tree only — the real files are never touched."""
    global _failures
    tmp = tempfile.mkdtemp(prefix="deploy-parity-selftest-")
    repo_dir = os.path.join(tmp, "repo", "server", "push_bridge")
    os.makedirs(repo_dir)
    repo = os.path.join(repo_dir, "main.py")
    with open(repo, "w") as f:
        f.write("x = 1\n")

    lkg_dir = os.path.join(tmp, "lkg")
    os.makedirs(lkg_dir)
    lkg = os.path.join(lkg_dir, "main.py")

    state = os.path.join(tmp, "state")
    os.makedirs(state)
    for n in ("shared_secret", "apns.env"):
        open(os.path.join(state, n), "w").close()

    unit = os.path.join(tmp, "unit.service")
    good_unit = (f"[Service]\nWorkingDirectory={repo_dir}\n"
                 f"ExecStart=/venv/bin/uvicorn main:app --port 9160\n")

    results = []

    def fresh():
        with open(lkg, "w") as f:
            f.write("x = 1\n")
        with open(unit, "w") as f:
            f.write(good_unit)

    # T1 all-fresh -> PASS
    fresh()
    _failures = 0
    rc = run(repo, lkg, unit, state)
    results.append(("T1 all-fresh -> PASS", rc == 0))

    # T2 stale LKG -> FAIL
    with open(lkg, "w") as f:
        f.write("x = 2\n")
    _failures = 0
    rc = run(repo, lkg, unit, state)
    results.append(("T2 stale LKG -> FAIL", rc == 1))

    # T3 wrong WorkingDirectory -> FAIL
    fresh()
    with open(unit, "w") as f:
        f.write(good_unit.replace(repo_dir, "/somewhere/else"))
    _failures = 0
    rc = run(repo, lkg, unit, state)
    results.append(("T3 wrong WorkingDirectory -> FAIL", rc == 1))

    # T4 broken repo py_compile -> FAIL (lkg kept identical so the ONLY
    # failing pin is the compile gate)
    fresh()
    with open(repo, "w") as f:
        f.write("def broken(:\n")
    with open(lkg, "w") as f:
        f.write("def broken(:\n")
    _failures = 0
    rc = run(repo, lkg, unit, state)
    results.append(("T4 repo syntax error -> FAIL", rc == 1))

    # T5 missing WorkingDirectory -> FAIL
    with open(repo, "w") as f:
        f.write("x = 1\n")
    with open(lkg, "w") as f:
        f.write("x = 1\n")
    with open(unit, "w") as f:
        f.write("[Service]\nExecStart=/venv/bin/uvicorn main:app\n")
    _failures = 0
    rc = run(repo, lkg, unit, state)
    results.append(("T5 missing WorkingDirectory -> FAIL", rc == 1))

    ok = True
    for name, passed in results:
        print(("PASS" if passed else "FAIL") + " " + name)
        ok = ok and passed
    return 0 if ok else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(run(REPO, LKG, UNIT, STATE_DIR, HEALTH_URL))
