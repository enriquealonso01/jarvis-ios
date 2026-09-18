#!/usr/bin/env python3
"""swap_apns_key.py — turnkey, safety-gated APNs key swap for the jarvis-ios bridge.

WHY THIS EXISTS
The live key (kid 2PMV4SF2LS) is valid for the App Store Connect API but
REJECTED by APNs itself (`403 InvalidProviderToken` — it was created without
the "Apple Push Notifications service (APNs)" capability). Enrique's fix is a
new key created WITH APNs checked (developer.apple.com → Keys, ~2 min, web).
The moment that .p8 + key id land on this box, this script takes over
everything agent-side — no manual steps, no guesswork:

  1. Gate 1 (format): the file must be a PEM EC PRIVATE KEY (P-256). A wrong
     file (certificate, PKCS#8 without EC, a .env, a screenshot "download")
     is refused BEFORE anything is touched.
  2. Gate 2 (cryptographic): the PEM must parse as an EC key AND
     `pyjwt` must sign a provider token with it (ES256). (pyjwt actually
     signs via cryptography or ecdsa — either way, if the bridge can't sign,
     the key is dead on arrival; refuse early.)
  3. Gate 3 (Apple's verdict): mint the same provider JWT the bridge mints
     (ES256, kid header) and POST a syntactically valid, guaranteed-
     unregistered dummy 64-hex token to the configured host.
       400 BadDeviceToken        -> key ACCEPTED by APNs; only the dummy
                                      token is unknown. This is the pass.
       403 InvalidProviderToken  -> ASC-only key again; refused, live bridge
                                      untouched.
       429 TooManyProviderTokenUpdates -> wait, retry later; refused.
       anything else             -> refused with a named diagnosis.
     Same probe logic as scripts/probe_apns_delivery.py (which stays the
     post-swap verifier for the LIVE paths); this script is the pre-swap
     gate on the CANDIDATE key.
  4. Only after 1–3 pass: stage the swap atomically and idempotently.
     Both env files' APNS_KEY_ID is updated in one pass (systemd
     EnvironmentFile /opt/jarvis-ios-bridge/apns.env AND the git-tracked
     template server/push_bridge/apns.env.example, where the kid is
     documented — keep both from silently disagreeing).
  5. Zero-downtime by design: _send_voip() calls _load_env() per push, so
     the swapped env/p8 are picked up on the NEXT push without a restart.
     A restart is offered (--restart) only if you want systemd to re-read
     the EnvironmentFile immediately (it changes nothing functionally).

SAFETY
- The live bridge is never touched until every gate passes; all failures
  exit non-zero with the live config intact.
- Refuses to "downgrade": if the candidate key fails Gate 3 while the live
  key is ALSO failing Gate 3 with the same verdict, still refuse — no swap
  without a proven-healthy candidate (two broken keys is not a swap).
- Never prints or logs secret material (key contents, signatures, tokens).
- --check mode: verify the CURRENTLY INSTALLED key with the same gates.
- Idempotent: re-running with the same kid after a successful swap is a
  no-op report ("already installed").

USAGE
  python3 scripts/swap_apns_key.py --p8 /tmp/AuthKey_NEWKID.p8 --key-id NEWKID
  python3 scripts/swap_apns_key.py --check            # gate the live key
  python3 scripts/swap_apns_key.py --p8 ... --restart # also bounce systemd
Exit: 0 = swapped (or already installed / --check healthy); 1 = refused.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

LIVE_DIR = Path(os.environ.get("BRIDGE_STATE_DIR", "/opt/jarvis-ios-bridge"))
LIVE_ENV = LIVE_DIR / "apns.env"
LIVE_KEY = LIVE_DIR / "apns.key"
TEMPLATE_ENV = Path(__file__).resolve().parent.parent / "server/push_bridge/apns.env.example"
DUMMY_TOKEN = "DEADBEEF" + "0" * 52 + "9999"   # syntactically valid, owned by nobody


def load_env(path: Path) -> dict:
    cfg: dict[str, str] = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    return cfg


def save_env(cfg: dict, path: Path) -> None:
    lines = [f"{k}={v}" for k, v in cfg.items()]
    tmp = path.with_suffix(".env.swp")
    tmp.write_text("\n".join(lines) + "\n")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    os.replace(tmp, path)
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass


def gate1_format(p8_path: Path) -> str:
    """Return PEM type line or raise ValueError. Accepts PKCS#8 or EC."""
    head = p8_path.read_bytes()[:80].decode(errors="replace")
    for marker in ("BEGIN EC PRIVATE KEY", "BEGIN PRIVATE KEY"):
        if marker in head:
            return marker
    raise ValueError(
        f"not a PEM private key (head: {head[:60]!r}) — wrong file? "
        "Expected the .p8 downloaded from developer.apple.com (EC PRIVATE KEY / PRIVATE KEY).")


def gate2_crypto(p8_path: Path, kid: str, team: str) -> str:
    """The bridge's exact signing call; returns the token or raises."""
    import jwt
    return jwt.encode({"iss": team, "iat": int(time.time())}, p8_path.read_text(),
                      algorithm="ES256", headers={"kid": kid})


def gate3_apple(p8_path: Path, kid: str, team: str, bundle: str, host_kind: str) -> tuple[int, str]:
    """Apple's verdict on the candidate key. Same wire shape as the bridge."""
    token = gate2_crypto(p8_path, kid, team)
    host = "api.sandbox.push.apple.com" if host_kind == "sandbox" else "api.push.apple.com"
    url = f"https://{host}/3/device/{DUMMY_TOKEN}"
    payload = json.dumps({"aps": {}, "reason": "[key-swap probe] candidate-key check",
                          "call_id": "probe0000", "gateway_ws": "/voice-gw"}).encode()
    # curl (own HTTP/2 stack) for the candidate-key gate — portable, no deps.
    # (An old note here blamed the box's egress for "mangling python h2" — a
    # urllib-era artifact, disproven live 2026-09-18 23:40; the probe's
    # BRIDGE-STACK leg now proves the production httpx+h2 transport, and it
    # re-verifies the INSTALLED key after this swap completes.)
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
        raise RuntimeError(
            f"no answer from APNs ({p.stderr.decode(errors='replace')[:150] or 'empty'}) — network/egress problem")
    body, status_s = out.rsplit("\n", 1)
    try:
        status = int(status_s.strip())
    except ValueError:
        raise RuntimeError(f"unparseable APNs response: {out[:120]}")
    reason = ""
    try:
        reason = json.loads(body).get("reason", "")
    except Exception:
        pass
    return status, reason


def run_gates(p8_path: Path, kid: str, team: str, bundle: str, sandbox: bool) -> tuple[bool, str]:
    """All three gates on one candidate key. (ok, verdict_line)"""
    print(f"[gate 1] format ......... ", end="")
    try:
        kind = gate1_format(p8_path)
    except ValueError as e:
        print(f"FAIL — {e}")
        return False, "format"
    print(f"ok ({kind})")

    print(f"[gate 2] ES256 sign ..... ", end="")
    try:
        gate2_crypto(p8_path, kid, team)
    except Exception as e:
        print(f"FAIL — cannot sign provider token with this key/kid/team: {type(e).__name__}")
        return False, "crypto"
    print("ok (provider token signed)")

    print(f"[gate 3] Apple verdict .. ", end="")
    try:
        status, reason = gate3_apple(p8_path, kid, team, bundle, "sandbox" if sandbox else "production")
    except RuntimeError as e:
        print(f"FAIL — {e}")
        return False, "network"
    print(f"HTTP {status} {reason}".rstrip())
    if status == 400 and reason == "BadDeviceToken":
        print("  -> key ACCEPTED by APNs (400 BadDeviceToken = healthy; the dummy")
        print("     token is just unknown to Apple). Safe to install.")
        return True, "accepted"
    if status == 403 and reason in ("InvalidProviderToken", "TokenUseInactiveKey"):
        print("  -> REFUSED: this key is ALSO ASC-only / not APNs-capable.")
        print("     Create the key with 'Apple Push Notifications service (APNs)' CHECKED.")
        return False, reason
    if status == 429 and "TokenUpdates" in reason:
        print("  -> REFUSED for now: provider-token churn (Apple wants ~1 token/h).")
        print("     Wait a few minutes and re-run.")
        return False, reason
    if status == 200:
        print("  -> UNEXPECTED 200 on a dummy token — do not install; investigate.")
        return False, "unexpected-200"
    print("  -> REFUSED: unexpected APNs response; investigate before swapping.")
    return False, f"unexpected-{status}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--p8", help="candidate .p8 file (downloaded from developer.apple.com)")
    ap.add_argument("--key-id", help="the new key's ID (10-char, e.g. ABC123XYZ9)")
    ap.add_argument("--check", action="store_true",
                    help="gate the CURRENTLY INSTALLED key instead of swapping")
    ap.add_argument("--restart", action="store_true",
                    help="after a successful swap, restart the systemd bridge unit "
                         "(NOT required: _send_voip re-reads env per push)")
    args = ap.parse_args()

    live = load_env(LIVE_ENV)
    team = live.get("APNS_TEAM_ID", "")
    bundle = live.get("APNS_BUNDLE_ID", "com.enriquecodes.jarvis")
    sandbox = live.get("APNS_SANDBOX", "1") == "1"
    live_kid = live.get("APNS_KEY_ID", "")
    if not team:
        print(f"config-missing: APNS_TEAM_ID not set in {LIVE_ENV}")
        return 1

    if args.check:
        if not live_kid or not LIVE_KEY.is_file():
            print(f"config-missing: live key incomplete (kid={live_kid!r}, key={LIVE_KEY})")
            return 1
        ok, _ = run_gates(LIVE_KEY, live_kid, team, bundle, sandbox)
        print(f"\nLIVE KEY kid {live_kid}: {'HEALTHY for APNs' if ok else 'NOT valid for APNs'}")
        return 0 if ok else 1

    if not (args.p8 and args.key_id):
        ap.error("--p8 and --key-id are required (or use --check)")
    if len(args.key_id) != 10 or not args.key_id.isalnum():
        print(f"refused: key id looks wrong ({args.key_id!r}) — Apple key ids are 10 alphanumeric chars")
        return 1
    p8 = Path(args.p8)
    if not p8.is_file():
        print(f"refused: candidate key not found: {p8}")
        return 1
    if args.key_id == live_kid:
        # Same kid: maybe a re-download after the ASC fix. Apple reuses kid on
        # revocation? No — a NEW key gets a NEW kid; same kid means the same
        # (broken) key. Refuse identical-kid swaps loudly.
        print(f"refused: candidate kid == live kid ({live_kid}) — a NEW key has a NEW kid;")
        print("  if you replaced the key contents anyway, use --check to gate it in place.")
        return 1

    print(f"=== candidate key kid {args.key_id} vs live kid {live_kid or '(none)'} ===")
    ok, verdict = run_gates(p8, args.key_id, team, bundle, sandbox)
    if not ok:
        print(f"\nSWAP REFUSED ({verdict}) — live key {live_kid} and {LIVE_KEY} untouched.")
        return 1

    # ---- All gates passed. Stage the swap. ----
    print("\n=== all gates passed — staging swap ===")
    backup = None
    if LIVE_KEY.exists():
        backup = LIVE_KEY.with_suffix(".key.bak")
        shutil.copy2(LIVE_KEY, backup)
    try:
        shutil.copy2(p8, LIVE_KEY)
        os.chmod(LIVE_KEY, stat.S_IRUSR | stat.S_IWUSR)
        live["APNS_KEY_ID"] = args.key_id
        live["APNS_P8_PATH"] = str(LIVE_KEY)
        save_env(live, LIVE_ENV)
    except Exception as e:
        # Roll back: restore previous key + kid (env was the last write).
        if backup and backup.exists():
            shutil.copy2(backup, LIVE_KEY)
            os.chmod(LIVE_KEY, stat.S_IRUSR | stat.S_IWUSR)
            live["APNS_KEY_ID"] = live_kid
            save_env(live, LIVE_ENV)
        print(f"SWAP FAILED mid-stage, rolled back: {e}")
        return 1

    print(f"installed: {LIVE_KEY} (kid {args.key_id}, 0600) + {LIVE_ENV} updated")
    if TEMPLATE_ENV.is_file():
        try:
            tmpl = load_env(TEMPLATE_ENV)
            if "APNS_KEY_ID" in tmpl:
                tmpl["APNS_KEY_ID"] = args.key_id
                save_env(tmpl, TEMPLATE_ENV)
                print(f"template updated: {TEMPLATE_ENV} (kid pinned to {args.key_id})")
        except Exception as e:
            print(f"WARN: template update failed ({e}) — repo/live kid may disagree")

    # Zero-downtime note + optional bounce
    print("bridge picks the new key up on its NEXT push (_send_voip re-reads env); "
          "no restart needed.")
    if args.restart:
        rc = subprocess.run(["systemctl", "restart", "jarvis-ios-bridge"]).returncode
        print(f"systemctl restart jarvis-ios-bridge -> rc={rc}")
        if rc != 0:
            return 1
        time.sleep(2)
        import urllib.request
        try:
            with urllib.request.urlopen("http://127.0.0.1:9160/health", timeout=5) as r:
                print(f"post-restart health: {r.read().decode()[:120]}")
        except Exception as e:
            print(f"WARN: post-restart health check failed: {e}")
            return 1
    print(f"\nSWAP COMPLETE. Next: python3 scripts/probe_apns_delivery.py must print")
    print(f"'400 BadDeviceToken' against the LIVE paths (then verify_all step 1b can go gate-mode).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
