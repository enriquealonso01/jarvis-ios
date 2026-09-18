#!/usr/bin/env python3
"""Doc-contract pins for jarvis-ios (added 2026-09-18).

Docs drift = the next agent (or Enrique, following docs/BUILD.md on his Mac)
follows a contract the code no longer honors. These checks pin the load-bearing
documented contracts to the actual code/probe behavior. Cheap, read-only.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []


def check(name, ok):
    print(("PASS" if ok else "FAIL"), "-", name)
    if not ok:
        failures.append(name)


# 1. docs/API.md /schedule/list entry shape must NOT include device_token —
#    the push-delivery secret is stripped from responses (PROGRESS 13:20).
api = open(os.path.join(ROOT, "docs", "API.md")).read()
i = api.find("- `GET /schedule/list`")
seg = api[i:api.find("\n- `POST", i)] if i >= 0 else ""
shapes = re.findall(r"\{scheduled: \[[^\]]*\]\}", seg)
check("API.md /schedule/list shape exists", bool(shapes))
check("API.md /schedule/list shape excludes device_token",
      bool(shapes) and "device_token" not in shapes[0])
check("API.md documents the strip (STRIPPED note present)", "STRIPPED" in seg)

# 2. Bridge code agrees: response entries are filtered.
bridge = open(os.path.join(ROOT, "server", "push_bridge", "main.py")).read()
check("bridge /schedule/list strips device_token + failures",
      'if k not in ("device_token", "failures")' in bridge)

# 3. Gateway doc contract: VoIP payload always carries gateway_ws "/voice-gw"
#    (docs/API.md note + bridge code must match).
gw = open(os.path.join(ROOT, "server", "push_bridge", "main.py")).read()
check("bridge VoIP payload carries gateway_ws",
      "gateway_ws" in gw and "/voice-gw" in gw)

# 4. Entitlement doc contract: BUILD.md promises Push Notifications capability;
#    project.yml must still wire CODE_SIGN_ENTITLEMENTS (swift_sanity pins the
#    file itself; this pins the doc pointer).
build = open(os.path.join(ROOT, "docs", "BUILD.md")).read()
check("BUILD.md still documents the Push Notifications capability requirement",
      "Push Notifications" in build)

# 5. /health device_registered contract (API.md): the documented boolean must
#    actually be returned by bridge health() — watch crons + Home rely on it
#    to detect the phone's /register handshake without exposing token material.
check("bridge /health returns device_registered",
      '"device_registered": bool(cfg.get("DEVICE_TOKEN"))' in bridge)
check("API.md documents device_registered in /health",
      "device_registered" in api[i:])

# 6. APNs key-swap runbook contract (added 2026-09-18 23:xx): when Enrique's
#    replacement key lands, scripts/swap_apns_key.py must keep enforcing the
#    three gates (format / ES256 sign / Apple dummy-token verdict) BEFORE any
#    live state is touched — a bad key must never be staged over a broken one.
swap = open(os.path.join(ROOT, "scripts", "swap_apns_key.py")).read()
check("swap script gates on Apple's BadDeviceToken verdict before staging",
      'reason == "BadDeviceToken"' in swap)
check("swap script gates on the InvalidProviderToken refusal",
      '"InvalidProviderToken"' in swap and "SWAP REFUSED" in swap)
check("swap script refuses same-kid 'swaps' (a new key has a new kid)",
      "candidate kid == live kid" in swap)
check("swap script stages with rollback (backup .key.bak + env restore)",
      ".key.bak" in swap and "rolled back" in swap)
check("BUILD.md names swap_apns_key.py as the install runbook",
      "swap_apns_key.py" in build)

# 7. Two-leg delivery-probe contract (added 2026-09-18 23:40): the probe's
#    verdict must cover the bridge's PRODUCTION transport (httpx + h2), not
#    just curl — a bridge-side transport regression can never hide behind a
#    curl-only green. Pins the BRIDGE-STACK leg, the both-legs verdict rule,
#    and the _send_voip transport guard it protects.
probe = open(os.path.join(ROOT, "scripts", "probe_apns_delivery.py")).read()
check("probe runs the BRIDGE-STACK leg (bridge venv httpx+h2)",
      "BRIDGE_STACK_LEG" in probe and "BRIDGE_PY" in probe)
check("probe passes the provider token via env, never argv",
      'APNS_LEG_TOKEN' in probe and '"-c", BRIDGE_STACK_LEG' in probe)
check("probe verdict requires both legs to agree",
      "legs_agree" in probe and "transport_broken" in probe)
check("probe names a distinct BRIDGE TRANSPORT BROKEN diagnosis",
      "BRIDGE TRANSPORT BROKEN" in probe)
check("_send_voip wraps the POST in a transport guard (LOUD, recorded False)",
      'TRANSPORT ERROR' in bridge and 'transport-guard contract' in bridge)
check("probe doc names the both-leg design",
      "Both legs" in probe or "BOTH legs" in probe)

# 8. Reminder-cron prompt contract (added 2026-09-18 23:45): agent-mode crons
#    aimed at Enrique must NOT contain stale guidance — the Sep-19 9AM guide
#    once claimed "the push bridge is live with the APNs key" AFTER that key
#    was discovered ASC-only (403 InvalidProviderToken). The live crons'
#    prompts must match their repo mirrors byte-identical (drift = silent
#    divergence from the reviewed text) and must be STATE-DRIVEN: they read
#    the probe/device verdicts before telling Enrique what to do.
mirs = {
    "apple-setup-guide": os.path.join(ROOT, "scripts", "cron_prompts", "apple_setup_guide.txt"),
    "loop-sunset": os.path.join(ROOT, "scripts", "cron_prompts", "loop_sunset.txt"),
}
LIVE_IDS = {"apple-setup-guide": "2203e22d518d", "loop-sunset": "3b3cf2b06cad"}
jobs_path = os.path.expanduser(os.path.join("~", ".hermes", "cron", "jobs.json"))
try:
    with open(jobs_path) as fh:
        _j = json.load(fh)
    live_jobs = {j.get("id"): j for j in (_j if isinstance(_j, list) else _j.get("jobs", []))}
    cron_store_ok = True
except Exception:
    live_jobs = {}
    cron_store_ok = False
check("cron jobs.json readable (prompt pins need it)", cron_store_ok)
guide_mirror = open(mirs["apple-setup-guide"]).read()
check("guide mirror is state-driven (runs probe + /health before advising)",
      "probe_apns_delivery" in guide_mirror and "/health" in guide_mirror)
check("guide mirror knows the ASC-only key failure mode (InvalidProviderToken)",
      "InvalidProviderToken" in guide_mirror and "BadDeviceToken" in guide_mirror)
check("guide mirror tells him the key step (developer.apple.com, APNs checked)",
      "developer.apple.com" in guide_mirror and "APNs" in guide_mirror)
check("guide mirror does NOT claim the live key delivers pushes",
      "bridge is live with the APNs key" not in guide_mirror)
sunset_mirror = open(mirs["loop-sunset"]).read()
check("sunset mirror checks probe verdict for the NEEDS-ENRIQUE list",
      "probe_apns_delivery" in sunset_mirror and "InvalidProviderToken" in sunset_mirror)
check("sunset mirror keeps the device-watch running after pausing the loop",
      "device-watch" in sunset_mirror)
for label, jid in LIVE_IDS.items():
    live = live_jobs.get(jid, {}).get("prompt", "")
    check(f"live cron {label} ({jid}) matches its repo mirror",
          bool(live) and live == open(mirs[label]).read())


print()
if failures:
    print(f"{len(failures)} DOC CONTRACT FAILURE(S)")
    sys.exit(1)
print("DOC CONTRACTS OK")
