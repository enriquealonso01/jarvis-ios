#!/usr/bin/env python3
"""poll_asc_builds.py — canonical ASC build-visibility poller (repo copy).

Background: builds 19/20/21 were uploaded to App Store Connect (app
6813590605, com.enriquecodes.jarvis) and accepted by the iTunes transport,
but zero build records ever materialized — a stuck ASC ingest state that
needs a one-time check in the ASC web UI (see PROGRESS 2026-09-18 19:30).
The testflight-build-watch cron runs this script every 15m until a build
record appears, then pings Enrique and self-removes.

Why in-repo: the original watcher script lived in /tmp with hardcoded key
IDs — a reboot would delete it and the cron would "end quietly" forever.
This copy reads everything from the bridge env file and takes parameters.

Usage:
  poll_asc_builds.py [--app APP_ID] [--expect VERSION] [--env FILE]

Exit codes: 0 = ok (build seen or still propagating), 1 = config error.
Prints a "BUILD:" line per visible build; the watcher treats any BUILD
line as the success signal.

Auth: the same ES256 .p8 the bridge uses for APNs doubles as the ASC API
key (issuer = ASC issuer ID, aud = appstoreconnect-v1).
"""
import argparse
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

DEFAULT_APP = "6813590605"          # ASC app record: EA's J.A.R.V.I.S
DEFAULT_ENV = "/opt/jarvis-ios-bridge/apns.env"
DEFAULT_KEY = "/opt/jarvis-ios-bridge/apns.key"
# ASC API issuer ID (differs from the APNs team ID; not a secret — it rides
# in every ASC JWT claim anyway).
DEFAULT_ISSUER = "cbd7e0fd-925b-4aa8-8ce1-facbc1b39881"


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--app", default=DEFAULT_APP)
    ap.add_argument("--expect", default=None,
                    help="only print BUILD lines for this version number")
    ap.add_argument("--control-app", default="6773857468",
                    help="second app whose latest build is printed as a "
                         "CONTROL line (differential: is ASC ingest delayed "
                         "team-wide, or specific to our app?). Empty string "
                         "disables.")
    ap.add_argument("--env", default=DEFAULT_ENV)
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--issuer", default=DEFAULT_ISSUER)
    args = ap.parse_args()

    env_path, key_path = Path(args.env), Path(args.key)
    if not env_path.is_file() or not key_path.is_file():
        print(f"config-missing: {env_path} / {key_path}", file=sys.stderr)
        return 1
    env = load_env(env_path)
    kid = env.get("APNS_KEY_ID")
    if not kid:
        print("config-missing: APNS_KEY_ID not in env file", file=sys.stderr)
        return 1

    try:
        import jwt
    except ImportError:
        print("deps-missing: pyjwt not importable", file=sys.stderr)
        return 1

    now = int(time.time())
    token = jwt.encode(
        {"iss": args.issuer, "iat": now, "exp": now + 1200,
         "aud": "appstoreconnect-v1"},
        key_path.read_text(), algorithm="ES256",
        headers={"kid": kid},
    )
    url = (f"https://api.appstoreconnect.apple.com/v1/builds"
           f"?filter[app]={args.app}&limit=10&sort=-uploadedDate")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        print(f"asc-error: HTTP {e.code}", file=sys.stderr)
        return 0  # transient — the watcher treats errors as "end quietly"
    except Exception as e:
        print(f"asc-error: {e}", file=sys.stderr)
        return 0

    data = d.get("data", [])
    print("count:", len(data))
    for b in data:
        a = b["attributes"]
        ver = str(a.get("version"))
        if args.expect and ver != str(args.expect):
            continue
        print(f"BUILD: {ver} | {a.get('processingState')} | {a.get('uploadedDate')}")
    print_control(args, token)
    return 0


def print_control(args, token: str) -> None:
    """Print the control app's latest build (differential diagnosis aid)."""
    if not args.control_app:
        return
    url = (f"https://api.appstoreconnect.apple.com/v1/builds"
           f"?filter[app]={args.control_app}&limit=1&sort=-uploadedDate")
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read().decode())
    except Exception as e:
        print(f"control: unreadable ({e})")
        return
    for b in d.get("data", []):
        a = b["attributes"]
        print(f"CONTROL: app {args.control_app} latest build "
              f"{a.get('version')} | {a.get('processingState')} | "
              f"{a.get('uploadedDate')}")


if __name__ == "__main__":
    sys.exit(main())
