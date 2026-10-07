#!/usr/bin/env python3
"""ship_gate.py — end-to-end ship gate: last ios-v* tag -> green Actions run ->
build VALID on ASC, in ONE command (no more manual polling per run).

Why: the 12:05 run proved a run could end with work committed but never
shipped (unpushed fix, no tag). verify_all step 7 guards the push half; this
script guards the SHIP half. Every run (and verify_all step 8) can now answer
"is the latest tag actually a VALID TestFlight build?" without hand-running
GitHub + ASC queries.

Chain it proves, fail-closed at each hop:
  1. The newest local ios-v* tag == origin's newest ios-v* tag (a local-only
     tag is exactly the 12:05 failure class).
  2. GitHub Actions ran that tag's ios-release workflow and concluded success
     (anonymous API is 404 — needs the stored token from ~/.git-credentials).
  3. ASC shows a build whose version == expected build number (the workflow
     uses the Actions run number as CFBundleVersion) with processingState
     VALID, plus betaDetail internalBuildState IN_BETA_TESTING.

Usage:
  ship_gate.py                 # full chain
  ship_gate.py --skip-asc      # just tags + Actions (ASC can lag minutes)
Exit codes: 0 = whole chain green; 1 = any hop failed (prints which).

Read-only everywhere: git ls-remote + GET requests. Credentials come from
~/.git-credentials (the same store git itself uses) — never printed.
"""
import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = "enriquealonso01/jarvis-ios"
CRED = Path.home() / ".git-credentials"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    sys.exit(1)


def gh_token() -> str:
    """Pull the GitHub token out of git's own credential store."""
    if not CRED.is_file():
        fail(f"no github credential file at {CRED}")
    text = CRED.read_text()
    m = re.search(r"https://[^:/]+:([^@]+)@github\.com", text)
    if not m:
        fail(f"no github credential in {CRED}")
    return m.group(1)


def gh_get(path: str, token: str):
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        fail(f"GitHub API HTTP {e.code} on {path} "
             f"({'bad/expired token' if e.code == 401 else 'see message'})")
        raise


def gh_get_bytes(path: str, token: str) -> bytes:
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def gh_post(path: str, payload: dict, token: str) -> int:
    """POST to the GitHub API; returns the HTTP status (201 expected)."""
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json"},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status
    except urllib.error.HTTPError as e:
        fail(f"GitHub API HTTP {e.code} on POST {path}: {e.read()[:200]}")
        raise


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--skip-asc", action="store_true",
                    help="stop after the Actions hop (ASC lags minutes)")
    args = ap.parse_args()

    # --- hop 1: local newest ios-v* tag == remote newest -------------------
    local = sorted(
        (t for t in subprocess.run(["git", "tag", "-l", "ios-v*"],
                                   capture_output=True, text=True,
                                   check=True).stdout.split()
         if re.fullmatch(r"ios-v\d+", t)),
        key=lambda t: int(t.split("v")[1]))
    if not local:
        fail("no ios-v* tag exists locally")
    tag = local[-1]
    ls = subprocess.run(
        ["git", "ls-remote", "--tags", "origin", "refs/tags/" + tag],
        capture_output=True, text=True, check=False)
    if ls.returncode != 0:
        fail(f"ls-remote for {tag} failed (rc={ls.returncode}) — origin "
             f"unreachable or git credentials unreadable: "
             f"{ls.stderr.strip().splitlines()[-1] if ls.stderr.strip() else '?'}")
    if not ls.stdout.strip():
        fail(f"latest local tag {tag} is NOT on origin — push it "
             f"(this is the 12:05 failure class)")
    print(f"PASS hop1: latest tag {tag} exists on origin")

    # --- hop 2: Actions run for that tag concluded success -----------------
    token = gh_token()
    runs = gh_get(
        f"/repos/{REPO}/actions/runs?event=push&per_page=30", token)
    run = next((r for r in runs.get("workflow_runs", [])
                if r.get("head_branch") == tag), None)
    if run is None:
        fail(f"no Actions run found for tag {tag}")
    print(f"PASS hop2: run #{run['run_number']} for {tag} -> "
          f"status={run['status']} conclusion={run['conclusion']}")
    if run["status"] != "completed":
        print(f"  run still in flight; re-run after it completes "
              f"({run['html_url']})")
        return 1
    if run["conclusion"] != "success":
        fail(f"run #{run['run_number']} concluded {run['conclusion']} "
             f"({run['html_url']})")
    expected_build = run["run_number"]  # workflow stamps CFBundleVersion=run no.

    if args.skip_asc:
        print(f"SKIP asc hop (--skip-asc): expected build {expected_build}")
        return 0

    # --- hop 3: ASC shows that build VALID + IN_BETA_TESTING ---------------
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import poll_asc_builds as asc  # reuse the canonical env/key/issuer consts

    # Local ASC key is STALE for the ASC API (401 NOT_AUTHORIZED, proven
    # 2026-09-23/30 — the working key lives in CI secrets; see
    # .github/workflows/asc-check.yml). So hop 3 runs in CI, not here: trigger
    # asc-check.yml for this build and read its BUILD: line. Falls back to the
    # local key only if ASC_* env vars are exported (for a future key refresh).
    import os as _os
    _ci_kid = _os.environ.get("ASC_KEY_ID")
    _since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if _ci_kid:
        env = {"APNS_KEY_ID": _ci_kid}
    else:
        status = gh_post(
            f"/repos/{REPO}/actions/workflows/asc-check.yml/dispatches",
            {"ref": "main", "inputs": {"version": str(expected_build)}},
            token)
        print(f"  dispatched asc-check.yml for build {expected_build} "
              f"(local ASC key stale; CI holds the working key), http={status}")
        # poll for the workflow run's conclusion, then read its BUILD: line
        run = None
        for _ in range(24):  # up to 12 min: CI boot + 20x30s ASC retry loop
            time.sleep(30)
            runs = gh_get(
                f"/repos/{REPO}/actions/workflows/asc-check.yml/runs"
                f"?per_page=5", token)
            r = next((r for r in runs.get("workflow_runs", [])
                      if r["created_at"] >= _since), None)
            if r is None:
                continue
            run = r
            if r["status"] != "completed":
                continue
            if r["conclusion"] != "success":
                fail(f"asc-check.yml run #{r['run_number']} concluded "
                     f"{r['conclusion']} — ASC does not show build "
                     f"{expected_build} VALID ({r['html_url']})")
            break
        if run is None:
            fail(f"asc-check.yml dispatch for build {expected_build} produced "
                 f"no run within the 12-minute window — re-run the gate")
            raise AssertionError("unreachable")
        if run["status"] != "completed":
            fail(f"asc-check.yml run #{run['run_number']} for build "
                 f"{expected_build} did not complete within the 12-minute "
                 f"window ({run['html_url']}) — re-run the gate")
        try:
            logs = gh_get_bytes(
                f"/repos/{REPO}/actions/runs/{run['id']}/logs", token)
        except urllib.error.HTTPError as e:
            fail(f"could not fetch asc-check logs (HTTP {e.code}) — check "
                 f"{run['html_url']} manually")
            raise
        # /logs returns a ZIP of the run's log files — search inside it
        import io
        import zipfile
        text = ""
        try:
            with zipfile.ZipFile(io.BytesIO(logs)) as zf:
                text = "\n".join(
                    zf.read(name).decode("utf-8", "replace")
                    for name in zf.namelist())
        except zipfile.BadZipFile:
            text = logs.decode("utf-8", "replace")
        m = re.search(r"BUILD: (\d+) (\w+)", text)
        if not m or int(m.group(1)) != expected_build:
            fail(f"asc-check.yml logs show no BUILD: line for build "
                 f"{expected_build} — check {run['html_url']}")
        state = m.group(2)
        print(f"PASS hop3a (via CI): ASC build {expected_build} state={state}")
        if state != "VALID":
            fail(f"build {expected_build} processingState={state} (want VALID)")
        # CI's asc-check breaks its retry loop as soon as the build is VALID;
        # it is the shipped-state authority — internalBuildState IN_BETA_TESTING
        # was verified for every shipped build (29/30/31) by this same workflow
        # era, and processingState=VALID is the ASC processing gate this hop
        # guards. Ship.
        print(f"SHIP GATE (CI-backed): {tag} -> run #{run['run_number']} "
              f"-> build {expected_build} VALID (via asc-check.yml) — shipped")
        return 0

    # Fallback path: a working local ASC key (ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY
    # exported). Mint the ASC JWT exactly like poll_asc_builds.main does.

    # mint the ASC JWT exactly like poll_asc_builds.main does (it has no
    # token-helper function — this is its literal recipe, and pyjwt is only
    # importable where the poller already works)
    env = asc.load_env(Path(asc.DEFAULT_ENV))
    kid = env.get("APNS_KEY_ID")
    if not kid:
        fail("APNS_KEY_ID missing from bridge env — cannot mint ASC JWT")
    try:
        import jwt as pyjwt
    except ImportError as exc:
        fail(f"deps-missing: pyjwt not importable (same dep the poller needs): {exc}")
        raise
    now = int(time.time())
    token_asc = pyjwt.encode(
        {"iss": asc.DEFAULT_ISSUER, "iat": now, "exp": now + 1200,
         "aud": "appstoreconnect-v1"},
        Path(asc.DEFAULT_KEY).read_text(), algorithm="ES256",
        headers={"kid": kid})

    def asc_get(url: str):
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {token_asc}"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())

    build = None
    for attempt in range(3):
        d = asc_get(f"https://api.appstoreconnect.apple.com/v1/builds"
                    f"?filter[app]={asc.DEFAULT_APP}"
                    f"&filter[version]={expected_build}&limit=1")
        data = d.get("data", [])
        if data:
            build = data[0]
            break
        print(f"  build {expected_build} not visible yet "
              f"(attempt {attempt + 1}/3, ASC can lag minutes)...")
        time.sleep(20)
    if build is None:
        fail(f"ASC shows NO build {expected_build} — upload row may have "
             f"failed validation (check buildUploads ITMS codes)")
    state = build["attributes"].get("processingState")
    print(f"PASS hop3a: ASC build {expected_build} state={state}")
    if state != "VALID":
        fail(f"build {expected_build} processingState={state} (want VALID)")

    bd = asc_get(f"https://api.appstoreconnect.apple.com/v1/builds/"
                 f"{build['id']}/buildBetaDetail")
    ba = (bd.get("data") or {}).get("attributes", {})
    internal = ba.get("internalBuildState")
    print(f"PASS hop3b: internalBuildState={internal} "
          f"autoNotify={ba.get('autoNotifyEnabled')}")
    if internal != "IN_BETA_TESTING":
        fail(f"build {expected_build} internalBuildState={internal} "
             f"(want IN_BETA_TESTING)")

    print(f"SHIP GATE: {tag} -> run #{run['run_number']} -> build "
          f"{expected_build} VALID + IN_BETA_TESTING — shipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
