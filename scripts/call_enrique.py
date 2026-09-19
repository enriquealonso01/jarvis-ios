#!/usr/bin/env python3
"""call_enrique — the agent-facing entry point to the JARVIS-iOS push bridge.

Backlog #8 integration: any JARVIS surface (this cron loop, WhatsApp/Signal
chat, the voice brain's tool layer, a reminder cron) rings or schedules a
call to Enrique's iPhone with one command. Wraps docs/API.md recipe:

    POST /call                       {reason, scheduled_by?}          -> ring now
    POST /schedule                   {at_iso, reason, scheduled_by?}  -> later
    GET  /schedule/list                                                -> pending
    POST /schedule/cancel            {call_id?} (omit = cancel all)

Auth: HMAC-SHA256 over the raw body with the bridge shared secret
(/opt/jarvis-ios-bridge/shared_secret, root-only). GET /schedule/list signs
the empty body. The secret is read at call time and never printed.

Usage:
  call_enrique.py call     --reason "Market update" [--by "cron:jobname"]
  call_enrique.py schedule --at "2026-09-19T14:00:00+00:00" --reason "..." [--by ...]
  call_enrique.py list
  call_enrique.py cancel --id ab12cd34  # one
  call_enrique.py cancel --yes          # ALL (explicit: no undo)

Exit codes: 0 success (even pushed:false — see below), 1 usage/config error,
2 bridge unreachable/HTTP error. `pushed:false` on /call means APNs is not
configured OR no device has registered yet; the JSON says which state.

Schedule validation (2026-09-19, mirrored bridge-side): `--at` must be a
FUTURE ISO-8601 timestamp. Garbage timestamps exit 1 here without a network
call; past timestamps exit 1 too (the bridge 400s them — the scheduler fires
any persisted entry the moment it is due, so a past `--at` would ring
instantly). Naive (no-offset) timestamps are accepted and treated as UTC by
both sides — pass an explicit offset when in doubt.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import socket
import sys
import urllib.error
import urllib.request
from pathlib import Path

BRIDGE = "http://127.0.0.1:9160"
SECRET_PATH = Path("/opt/jarvis-ios-bridge/shared_secret")


def _sign(body: bytes) -> str:
    secret = SECRET_PATH.read_bytes().strip()
    return hmac.new(secret, body, hashlib.sha256).hexdigest()


def _request(method: str, path: str, body: dict | None = None) -> dict:
    raw = json.dumps(body).encode() if body is not None else b""
    req = urllib.request.Request(
        BRIDGE + path, data=raw if method == "POST" else None, method=method,
        headers={"Content-Type": "application/json", "x-bridge-sig": _sign(raw)})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:200]
        print(f"bridge HTTP {e.code}: {detail}", file=sys.stderr)
        sys.exit(2)
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        print(f"bridge unreachable at {BRIDGE}: {e}", file=sys.stderr)
        sys.exit(2)


def main() -> None:
    p = argparse.ArgumentParser(description="Ring or schedule a call to Enrique's iPhone (JARVIS-iOS push bridge).")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("call", help="ring now")
    c.add_argument("--reason", required=True)
    c.add_argument("--by", default=None, help="who asked (e.g. 'cron:jobname', 'voice', 'chat')")

    s = sub.add_parser("schedule", help="ring at an ISO-8601 time (prefer +00:00 offset)")
    s.add_argument("--at", required=True, dest="at_iso")
    s.add_argument("--reason", required=True)
    s.add_argument("--by", default=None)

    sub.add_parser("list", help="list pending scheduled calls")

    x = sub.add_parser("cancel", help="cancel one (--id) or ALL scheduled calls")
    x.add_argument("--id", default=None, help="call_id from `list`; omit to cancel ALL")
    x.add_argument("--yes", action="store_true",
                   help="required with cancel-ALL (no --id): the bridge refuses "
                        "an unconfirmed wipe of every pending call (no undo)")

    a = p.parse_args()
    if not SECRET_PATH.exists():
        print(f"missing {SECRET_PATH} (run on the JARVIS box as root)", file=sys.stderr)
        sys.exit(1)

    if a.cmd == "call":
        # Client-side mirror of the bridge's 2026-09-19 reason text guards
        # (1g): the reason rides the APNs payload, so empty or >3500-byte
        # text fails HERE at composition time (exit 1, no network call)
        # instead of a 400 after the fact.
        reason = (a.reason or "").strip()
        if not reason:
            print("--reason must not be empty (it is what the call screen "
                  "shows)", file=sys.stderr)
            sys.exit(1)
        if len(reason.encode("utf-8")) > 3500:
            print(f"--reason too long ({len(reason.encode('utf-8'))} bytes "
                  f"UTF-8 > 3500; the bridge 400s it — APNs rejects payloads "
                  f"over 4096 bytes)", file=sys.stderr)
            sys.exit(1)
        body: dict = {"reason": reason}
        if a.by:
            body["scheduled_by"] = a.by
        out = _request("POST", "/call", body)
        if not out.get("pushed"):
            print("NOTE pushed=false — APNs unconfigured or device not registered yet (bridge /health says which).")
    elif a.cmd == "schedule":
        # Client-side mirror of the bridge's 2026-09-19 /schedule guards:
        # fail at composition time (exit 1, no network call) instead of
        # persisting a silent-never or instant-fire entry.
        from datetime import datetime, timezone
        try:
            due = datetime.fromisoformat(a.at_iso.strip())
        except ValueError:
            print(f"--at '{a.at_iso}' is not a valid ISO-8601 timestamp "
                  f"(example: 2026-09-19T14:00:00+00:00)", file=sys.stderr)
            sys.exit(1)
        if due.tzinfo is None:
            print("NOTE: --at has no UTC offset; bridge will treat it as UTC.", file=sys.stderr)
            due = due.replace(tzinfo=timezone.utc)
        if due <= datetime.now(timezone.utc):
            print(f"--at '{a.at_iso}' is in the past — refusing (the bridge "
                  f"400s past timestamps; a schedule must be in the future).",
                  file=sys.stderr)
            sys.exit(1)
        body = {"at_iso": a.at_iso, "reason": (a.reason or "").strip()}
        if len(body["reason"].encode("utf-8")) > 3500:
            print(f"--reason too long ({len(body['reason'].encode('utf-8'))} "
                  f"bytes UTF-8 > 3500; the bridge 400s it — an oversized "
                  f"reason could never be delivered (APNs rejects payloads "
                  f"over 4096 bytes, so it would burn 10 retries then "
                  f"silently drop)", file=sys.stderr)
            sys.exit(1)
        if a.by:
            body["scheduled_by"] = a.by
        out = _request("POST", "/schedule", body)
    elif a.cmd == "list":
        out = _request("GET", "/schedule/list")
    else:
        # Cancel guard (1j, mirrored bridge-side): a whitespace-only --id must
        # fail HERE — it used to reach the bridge as a truthy-but-unmatchable
        # call_id and the request said nothing about what it would do.
        if a.id is not None and not a.id.strip():
            print("--id is whitespace-only — pass a call_id from `list`, or "
                  "omit --id (with --yes) to cancel ALL", file=sys.stderr)
            sys.exit(1)
        if a.id:
            body = {"call_id": a.id}
        else:
            # Cancel-ALL is the one bridge write that wipes EVERY pending call
            # with no undo. Bridge-side (1j) it now requires {"confirm": true};
            # the CLI mirrors that with an explicit --yes so an agent cannot
            # nuke the schedule with a bare `cancel` reflex.
            if not a.yes:
                print("cancel-ALL wipes every pending call and cannot be undone "
                      "-- re-run with --yes, or target one call with "
                      "--id <call_id from list>", file=sys.stderr)
                sys.exit(1)
            body = {"confirm": True}
        out = _request("POST", "/schedule/cancel", body)

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
