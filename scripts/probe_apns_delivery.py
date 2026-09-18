#!/usr/bin/env python3
"""probe_apns_delivery.py — prove the bridge's APNs delivery path end-to-end,
WITHOUT a phone.

Background: every prior run verified `_send_voip` only in its *unconfigured*
branch (`pushed:false` because no DEVICE_TOKEN). The p8 IS installed
(apns_configured:true), but no device has ever registered, so the REAL
delivery path — ES256 provider-token auth, topic, host, and Apple's verdict
on the key itself — stayed unexercised until 2026-09-18 22:xx, when this probe
found the live key answers `403 InvalidProviderToken` (works for the App Store
Connect API, rejected by APNs — see PROGRESS.md). Finding it NOW means the
very first real "call me" won't silently fail.

How: mint the same provider JWT the bridge mints (pyjwt ES256, kid header),
POST to the configured APNs host with a syntactically valid but NONEXISTENT
64-hex device token.

Verdicts (HTTP status + Apple's JSON `reason`):
  400 BadDeviceToken  -> PROVEN: token auth works, topic accepted, key valid
                         for APNs; only the (dummy) token is unknown. This is
                         the healthy "no phone yet" state.
  403 InvalidProviderToken / TokenUseInactiveKey -> key not valid for APNs
                         (created without the APNs capability, or an ASC-only
                         key) -> needs a new key from developer.apple.com
                         -> Keys with "Apple Push Notifications service (APNs)"
                         checked. THIS IS THE CURRENT LIVE VERDICT.
  429 TooManyProviderTokenUpdates -> provider-token churn: Apple wants ONE
                         token per ~1h. This probe CACHES its token for 45 min
                         to respect that; if you still hit 429, wait it out.
  200                 -> would mean Apple accepted a bogus token (impossible;
                         report loudly).

Safety: the dummy token is 64 hex chars no device owns; even on a freak 200 no
phone rings. Touches no bridge state. Never prints or writes secret material
(the p8 is read only to sign; the JWT is cached 0600 in the state dir).

Usage:
  python3 scripts/probe_apns_delivery.py            # gate mode (CI/verify_all)
  python3 scripts/probe_apns_delivery.py --warn     # WARN-only (sweep step 2b)
Exit: 0 = delivery path proven; 1 = broken (or --warn: 0 with WARN line).
"""
from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_ENV = "/opt/jarvis-ios-bridge/apns.env"
DEFAULT_KEY = "/opt/jarvis-ios-bridge/apns.key"
TOKEN_CACHE = Path(os.environ.get("APNS_PROBE_TOKEN_CACHE", "/tmp/.apns_probe_token"))
TOKEN_TTL = 45 * 60  # Apple asks for ~1 token/hour; stay under with margin.

# Syntactically valid, guaranteed-unregistered 64-hex token. No device owns
# this; APNs will answer BadDeviceToken if everything else is healthy.
DUMMY_TOKEN = "DEADBEEF" + "0" * 52 + "9999"


def load_env(path: Path) -> dict:
    cfg = {}
    text = path.read_text() if path.is_file() else ""
    if text:
        for line in text.splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


def mint_or_cached_token(p8_path: Path, kid: str, team: str) -> tuple[int, str]:
    """Reuse a cached provider token (<45 min old) or mint + cache a new one.
    Apple rate-limits frequent token rotation (TooManyProviderTokenUpdates)."""
    import jwt
    now = int(time.time())
    if TOKEN_CACHE.is_file():
        try:
            cached_ts = int(TOKEN_CACHE.read_text().split(":")[0])
            if now - cached_ts < TOKEN_TTL:
                return cached_ts, TOKEN_CACHE.read_text().split(":", 1)[1]
        except Exception:
            pass
    tok = jwt.encode({"iss": team, "iat": now}, p8_path.read_text(),
                     algorithm="ES256", headers={"kid": kid})
    try:
        TOKEN_CACHE.write_text(f"{now}:{tok}")
        os.chmod(TOKEN_CACHE, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    except Exception:
        pass  # cache is best-effort
    return now, tok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--env", default=DEFAULT_ENV)
    ap.add_argument("--key", default=DEFAULT_KEY)
    ap.add_argument("--warn", action="store_true",
                    help="always exit 0; print WARN instead of failing the sweep")
    args = ap.parse_args()

    def fail(msg_lines: list[str]) -> int:
        for line in msg_lines:
            print(line)
        if args.warn:
            print("WARN (delivery path not yet proven — see lines above)")
            return 0
        return 1

    env_path, key_path = Path(args.env), Path(args.key)
    if not env_path.is_file():
        return fail([f"config-missing: {env_path}"])
    env = load_env(env_path)
    kid, team = env.get("APNS_KEY_ID"), env.get("APNS_TEAM_ID")
    bundle = env.get("APNS_BUNDLE_ID") or "com.enriquecodes.jarvis"
    sandbox = env.get("APNS_SANDBOX", "1") == "1"
    p8_path = Path(env.get("APNS_P8_PATH") or key_path)
    if not (kid and team):
        return fail(["config-missing: APNS_KEY_ID / APNS_TEAM_ID not set in env file"])
    if not p8_path.is_file():
        return fail([f"config-missing: p8 key not found at {p8_path}"])

    try:
        import jwt
    except ImportError:
        return fail(["deps-missing: pyjwt not importable"])

    _, token = mint_or_cached_token(p8_path, kid, team)

    host = "api.sandbox.push.apple.com" if sandbox else "api.push.apple.com"
    url = f"https://{host}/3/device/{DUMMY_TOKEN}"
    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": bundle,
        "apns-push-type": "voip",
        "apns-priority": "10",
    }
    payload = json.dumps({"aps": {}, "reason": "[probe] delivery-path check",
                          "call_id": "probe0000", "gateway_ws": "/voice-gw"}).encode()
    # curl (its own HTTP/2 stack) instead of urllib: this box's egress mangles
    # HTTP/2 to Apple (double-GET quirk) and urllib would speak HTTP/1.1 into
    # an h2-only listener (BadStatusLine with binary preface). curl -w gives
    # status; body carries Apple's JSON `reason`.
    p = subprocess.run(
        ["curl", "-s", "--http2", "-o", "-", "-w", "\n%{http_code}", "--max-time", "15",
        "-X", "POST", url,
        "-H", f"authorization: bearer {token}",
        "-H", f"apns-topic: {bundle}",
        "-H", "apns-push-type: voip",
        "-H", "apns-priority: 10",
        "-H", "Content-Type: application/json",
        "--data-binary", "@-"],
        input=payload, capture_output=True)
    out = p.stdout.decode(errors="replace")
    if "\n" not in out.strip():
        return fail([f"PROBE-ERROR: no answer from APNs ({p.stderr.decode(errors='replace')[:150] or 'empty'}) — network/egress problem"])
    body, status_s = out.rsplit("\n", 1)
    try:
        status = int(status_s.strip())
    except ValueError:
        return fail([f"PROBE-ERROR: unparseable APNs response: {out[:150]}"])

    reason = ""
    try:
        reason = json.loads(body).get("reason", "")
    except Exception:
        pass

    print(f"APNs {host}: HTTP {status} {reason}".rstrip())

    if status == 400 and reason == "BadDeviceToken":
        print("VERDICT: delivery path PROVEN — provider token accepted, topic "
              "accepted, key valid for APNs; only the (dummy) device token is "
              "unknown. First real push goes through the moment a device "
              "registers.")
        return 0
    if status == 429 and "TokenUpdates" in reason:
        return fail(["VERDICT: token churn — cached token still too fresh on "
                     "Apple's side; wait a few minutes and re-run."])
    if status == 403:
        lines = ["VERDICT: KEY REJECTED BY APNs — fix before any real call."]
        if reason in ("InvalidProviderToken", "TokenUseInactiveKey"):
            lines += ["  The key is NOT valid for APNs (typically: created in "
                      "App Store Connect without the APNs capability, or the",
                      "  APNs checkbox was unticked). Fix: developer.apple.com "
                      "-> Certificates, Identifiers & Profiles -> Keys ->",
                      "  create key WITH 'Apple Push Notifications service "
                      "(APNs)' checked; install it per docs/API.md."]
        elif "Topic" in reason:
            lines += ["  topic/bundle mismatch: APNS_BUNDLE_ID must equal the "
                      "app's bundle id (com.enriquecodes.jarvis)."]
        else:
            lines += ["  check APNS_TEAM_ID (issuer) and the key itself."]
        return fail(lines)
    if status == 200:
        return fail(["VERDICT: UNEXPECTED 200 on a dummy token — report to the "
                     "loop agent (should be impossible)."])
    return fail(["VERDICT: unexpected APNs response — request shape needs a "
                 "look before first call."])


if __name__ == "__main__":
    sys.exit(main())
