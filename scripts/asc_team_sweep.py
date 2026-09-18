#!/usr/bin/env python3
"""asc_team_sweep.py — team-wide ASC ingest differential (one-shot).

Answers the question a single control app can't: is ASC ingest delayed for
EVERYTHING this team/key can see, or only for our app? Polls /v1/builds
paged by uploadedDate, groups the most recent build per app, and prints:
  RECENT: app <id> | build <v> | <state> | <uploadedDate>   (every app seen)
  MAX-AGE: <N> days since the newest build team-wide
If ANY app shows a build uploaded in the last 24h while our app shows zero,
the "stuck ingest" theory is dead (the pipeline works; our uploads are the
problem). If every app is frozen at old dates, a team-wide ingest stall is
confirmed.

Usage: asc_team_sweep.py [--env FILE] [--key FILE] [--issuer ID]
Exit: 0 = data gathered, 1 = config error.
"""
import argparse
import json
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_ENV = "/opt/jarvis-ios-bridge/apns.env"
DEFAULT_KEY = "/opt/jarvis-ios-bridge/apns.key"
DEFAULT_ISSUER = "cbd7e0fd-925b-4aa8-8ce1-facbc1b39881"  # ASC issuer (not APNs team)
OUR_APP = "6813590605"


def load_env(path: Path) -> dict:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def get_json(url: str, token: str):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--env", default=DEFAULT_ENV)
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--issuer", default=DEFAULT_ISSUER)
    ap.add_argument("--pages", type=int, default=4,
                    help="max pages of 100 builds to sweep (400 builds)")
    args = ap.parse_args()

    env_path, key_path = Path(args.env), Path(args.key)
    if not env_path.is_file() or not key_path.is_file():
        print(f"config-missing: {env_path} / {key_path}", file=sys.stderr)
        return 1
    kid = load_env(env_path).get("APNS_KEY_ID")
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

    # Page /v1/builds newest-first, no app filter. Each build's relationships
    # .app.data.id gives the owning app without a second request per app.
    url = ("https://api.appstoreconnect.apple.com/v1/builds"
           "?limit=100&sort=-uploadedDate")
    latest = {}  # app_id -> (version, state, uploaded_date)
    pages = 0
    try:
        while url and pages < args.pages:
            d = get_json(url, token)
            pages += 1
            for b in d.get("data", []):
                app_id = (b.get("relationships", {}).get("app", {})
                          .get("data", {}) or {}).get("id", "?")
                if app_id and app_id not in latest:
                    a = b["attributes"]
                    latest[app_id] = (a.get("version"), a.get("processingState"),
                                      a.get("uploadedDate"))
            url = (d.get("links") or {}).get("next")
    except urllib.error.HTTPError as e:
        print(f"asc-error: HTTP {e.code}", file=sys.stderr)
        return 0
    except Exception as e:
        print(f"asc-error: {e}", file=sys.stderr)
        return 0

    if not latest:
        print("NO BUILDS VISIBLE TEAM-WIDE (0 records in paged sweep) — "
              "strong evidence of a team/key-wide ingest stall.")
        return 0

    now_dt = datetime.now(timezone.utc)
    max_age = None
    for app_id, (ver, state, up) in sorted(latest.items()):
        tag = " (OUR APP)" if app_id == OUR_APP else ""
        print(f"RECENT: app {app_id}{tag} | build {ver} | {state} | {up}")
        if up:
            try:
                age = now_dt - datetime.fromisoformat(up.replace("Z", "+00:00"))
                if max_age is None or age < max_age:
                    max_age = age
            except ValueError:
                pass

    if max_age is not None:
        print(f"MAX-AGE: newest build team-wide is {max_age.total_seconds()/3600:.1f}h old")
        if max_age < timedelta(hours=24):
            print("VERDICT: other apps ARE ingesting builds <24h old — "
                  "ingest is NOT team-wide-stuck; our app's uploads are the problem.")
        else:
            print("VERDICT: no app on this team has ingested a build in >24h — "
                  "consistent with a team-wide ingest stall (ASC-side).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
