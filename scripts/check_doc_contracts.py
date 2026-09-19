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
#    1k: the shape now ALSO carries the scheduler drop log (dropped: [...]);
#    the regex matches the scheduled shape up to the first `]` either way.
api = open(os.path.join(ROOT, "docs", "API.md")).read()
i = api.find("- `GET /schedule/list`")
seg = api[i:api.find("\n- `POST", i)] if i >= 0 else ""
shapes = re.findall(r"\{scheduled: \[[^\]]*\]", seg)
check("API.md /schedule/list shape exists", bool(shapes))
check("API.md /schedule/list shape excludes device_token",
      bool(shapes) and "device_token" not in shapes[0])
check("API.md documents the strip (STRIPPED note present)", "STRIPPED" in seg)

# 2. Bridge code agrees: response entries are filtered.
bridge = open(os.path.join(ROOT, "server", "push_bridge", "main.py")).read()
check("bridge /schedule/list strips device_token + failures",
      'if k not in ("device_token", "failures")' in bridge)

# 2b. Scheduler drop log (1k, 2026-09-19): API.md must document BOTH
# surfacing keys (health dropped_calls, list dropped) and the bridge must
# keep them wired — a silent drop (the silent-never class) must be visible
# in docs AND code or the next agent debugs a ghost.
check("API.md documents dropped_calls in /health",
      "dropped_calls" in api)
check("API.md /schedule/list documents the dropped log",
      re.search(r"dropped: \[", api) is not None)
check("bridge /schedule/list returns the dropped log",
      'return {"scheduled": public, "dropped": _load_drops()}' in bridge)
check("bridge /health returns dropped_calls",
      '"dropped_calls": len(_load_drops())' in bridge)
check("bridge records scheduler drops (both sites)",
      bridge.count("_record_drop(") >= 3)

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

# 8b. Build-number + channel freshness in Enrique-facing one-shots (added
#     2026-09-19): the mirrors once told him to "install build 1 — the FIRST
#     and ONLY build" AFTER build 29 shipped, and routed the ring test over
#     WhatsApp AFTER that channel went 403. Contracts, future-proof (they
#     survive build 30+ on purpose):
#       - never name build 1 as the only/latest build to install;
#       - always give the STATE-DRIVEN instruction ("HIGHEST build number");
#       - never route the ring test to WhatsApp.
stale_claims = [
    "build 1 is the first and only build",
    "the FIRST and ONLY build",
    "install JARVIS **build 1**",
    "(build 1 LIVE",
    "TestFlight build 1",
    "install build 1",
]
ring_on_whatsapp = "'JARVIS, ring this phone' on WhatsApp"
for label, mirror in (("guide", guide_mirror), ("sunset", sunset_mirror)):
    for claim in stale_claims:
        check(f"{label} mirror carries no stale build-1 claim ({claim[:30]}...)",
              claim not in mirror)
    check(f"{label} mirror gives the highest-build-number instruction",
          "HIGHEST build number" in mirror)
    check(f"{label} mirror never routes the ring test to WhatsApp",
          ring_on_whatsapp not in mirror)
check("guide mirror does not claim the live key delivers pushes",
      "bridge is live with the APNs key" not in guide_mirror)
for label, jid in LIVE_IDS.items():
    live = live_jobs.get(jid, {}).get("prompt", "")
    check(f"live cron {label} ({jid}) matches its repo mirror",
          bool(live) and live == open(mirs[label]).read())


# 9. Push-success counter contract (added 2026-09-19): /health carries
#    push_ok/push_fail — totals of REAL Apple round-trips — because
#    last_push_error=="" means only "nothing failed YET". The device-watch
#    endgame verifies its verification push through these counters (call
#    fired via call_enrique.py, push_ok must increment) BEFORE claiming
#    "pushed:true"; failure is LOUD and fail-closed (cron stays).
bridge_src = bridge  # (already read above)
check("bridge defines the counter bump helper",
      "_bump_push_counters" in bridge_src and "push_ok" in bridge_src and "push_fail" in bridge_src)
check("bridge early-exits are NOT counted (round-trip-only semantics)",
      "NOT counted" in bridge_src)
check("/health exposes push_ok + push_fail",
      '"push_ok":' in bridge_src.replace(" ", "") or '"push_ok"' in bridge_src)
watch_src = open(os.path.join(ROOT, "scripts", "testflight_device_watch.sh")).read()
check("watch endgame fires a real verification call (call_enrique.py)",
      "call_enrique.py call" in watch_src and "push_ok" in watch_src)
check("watch endgame is fail-closed (URGENT branch, cron NOT removed)",
      "URGENT" in watch_src and "PUSH_OK_BEFORE" in watch_src and "PUSH_OK_NOW" in watch_src)
check("watch extracts push_ok whitespace-tolerantly (spaced JSON)",
      '"push_ok":[[:space:]]*[0-9]+' in watch_src)
check("API.md documents the push counters",
      "push_ok" in api and "REAL Apple round-trips" in api)


# 10. Watch-of-the-watch sentinel contract (added 2026-09-19): after the
#     23:00 UTC sunset pauses the build-loop cron, the 15m device-watch is
#     the mission's ONLY autonomous announcer. jarvis-ios-watch-sentinel
#     (30m, no-LLM) guards it — cron exists/enabled/ticks-fresh/budget,
#     bridge reachable, probe verdict alive — and alerts the TF Ops group
#     (latched, one-shot) on any coverage loss. It must stay
#     observe-and-report: it never mutates hermes state itself.
sentinel_src = open(os.path.join(ROOT, "scripts", "jarvis_ios_watch_sentinel.sh")).read()
arch = open(os.path.join(ROOT, "docs", "ARCHITECTURE.md")).read()
check("sentinel guards the device-watch job by name",
      'JOB=jarvis-ios-device-watch' in sentinel_src)
check("sentinel is observe-and-report (no hermes invocations)",
      "HERMES=" not in sentinel_src and "$(hermes" not in sentinel_src)
check("sentinel alerts are latched (one-shot per fault)",
      "sentinel_alert_" in sentinel_src and "grep -q '^sentinel_alert_" in sentinel_src)
check("sentinel always exits 0 (failure channel never fires spuriously)",
      "exit 0" in sentinel_src and "exit 1" not in sentinel_src)
check("sentinel GONE verdict is health-arbitrated (mission-complete"
      " self-remove stands down silently via device_registered+push_ok)",
      "MISSION_DONE" in sentinel_src and "push_ok" in sentinel_src)
check("ARCHITECTURE.md documents the watch-of-the-watch layer",
      "watch-sentinel" in arch and "jarvis-ios-watch-sentinel" in arch)

# 8c. Build-number freshness in the device-watch script (added 2026-09-19
#     ~17:00 UTC): contract 8b covered the one-shot mirrors but the watch's
#     own WAIT/KEY-LIVE lines still told Enrique to "install TestFlight
#     build 1" AFTER build 30 shipped — and after tonight's 23:00 sunset the
#     watch is the ONLY announcer left, so a stale instruction there is the
#     last thing he'd read. Future-proof: the watch must be build-number
#     AGNOSTIC (state-driven "HIGHEST build" phrasing), never name build 1
#     as the build to install, and never route anything to WhatsApp.
for claim in stale_claims:
    check(f"watch script carries no stale build-1 claim ({claim[:30]}...)",
          claim not in watch_src)
check("watch script gives the highest-build-number instruction",
      "HIGHEST build" in watch_src)
check("watch script never routes anything to WhatsApp",
      "WhatsApp" not in watch_src)

# 8d. BUILD.md freshness (added 2026-09-19 ~18:05 UTC): contracts 8b/8c
#     covered the cron mirrors and the watch script, but docs/BUILD.md — the
#     doc Enrique actually opens on his Mac for the phone-side steps, and the
#     one ARCHITECTURE.md's "gated ladder" points him at — sat in the
#     scanner's blind spot: its "Remaining:" section still told him to
#     "install build 1" AFTER build 30 shipped, and it still routed update
#     notices "via WhatsApp DM" (403 since Sep 18) / described the watch as
#     announcing to his personal Signal DM (UNREGISTERED_FAILURE since
#     Sep 19). Same failure class, last unread surface. Pins (BUILD.md-scoped
#     on purpose: the mirrors/watch legitimately MENTION the dead channels
#     only in "do NOT deliver there" context, and the mirrors carry
#     historical narration BUILD.md doesn't):
#       - never instruct installing build 1 (any "build 1" mention);
#       - always give the state-driven "HIGHEST build" instruction;
#       - no WhatsApp as a delivery/update channel;
#       - no claim that the watch announces to his personal Signal DM.
build_claims = [
    "install build 1",
    "via WhatsApp DM",
    "announcements → Enrique's personal Signal DM",
]
for claim in build_claims:
    check(f"BUILD.md carries no stale claim ({claim[:36]}...)",
          claim not in build)
check("BUILD.md gives the state-driven highest-build instruction",
      "HIGHEST build number" in build)
check("BUILD.md delivery is the TF Ops Signal group, never WhatsApp/DM",
      "TF Ops Signal group" in build)


print()
if failures:
    print(f"{len(failures)} DOC CONTRACT FAILURE(S)")
    sys.exit(1)
print("DOC CONTRACTS OK")
