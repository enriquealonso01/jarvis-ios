#!/bin/bash
# jarvis_ios_watch_sentinel.sh — no-LLM guardian for jarvis-ios-device-watch.
#
# WHY: after the 23:00 UTC sunset pauses the build-loop cron, the 15m
# device-watch is the ONLY autonomous announcer for the two remaining flips
# (APNs key accepted / phone /register). If the watch itself dies (removed,
# paused, ticks exhausted, script broken, bridge or probe unreadable) the
# mission's completion would silently depend on a dead process. This sentinel
# runs every 30m, costs zero LLM, is SILENT when everything is healthy, and
# alerts the TF Ops group (one line, latched in /tmp) if the watch loses
# guarding coverage:
#
#   1. watch cron exists (removed = flip completed OR real loss -> if the
#      bridge health is unreadable we cannot tell which: alert once, then
#      STAND DOWN — if this was mission-complete the watch already delivered
#      MISSION COMPLETE; if it was a real loss, one alert already fired)
#   2. watch enabled (paused -> alert; an agent can intentionally pause only
#      with an approved replacement announcer, which would update this script)
#   3. watch ticks advancing (last_run_at newer than previous poll; gap
#      > 40m = stalled -> alert)
#   4. tick budget: remaining = times - completed must stay > 8 (2h headroom
#      at 15m) -> alert before expiry, not after
#   5. bridge reachable on :9160 (the watch's data source)
#   6. probe still produces a VERDICT line (its failure mode is the watch's
#      flip-1 going permanently blind)
#
# One-time alerts via state file; re-arm only by a successful check, so a
# fixed condition does not re-fire, and a still-broken condition does not
# spam. Stand-down (condition 1 with unreadable bridge) is also one-shot.
# All paths overridable via env for sandbox testing (JARVIS_IOS_*).
set -u
STATE="${JARVIS_IOS_SENTINEL_STATE:-/tmp/.jarvis_ios_watch_sentinel_state}"
JOBS="${JARVIS_IOS_JOBS:-/root/.hermes/cron/jobs.json}"
PROBE="${JARVIS_IOS_PROBE:-/root/projects/jarvis-ios/scripts/probe_apns_delivery.py}"
BRIDGE="${JARVIS_IOS_BRIDGE:-http://127.0.0.1:9160}"
JOB=jarvis-ios-device-watch
WATCH_LIVE="${JARVIS_IOS_WATCH_LIVE:-/root/.hermes/scripts/testflight_device_watch.sh}"
[ -f "$STATE" ] || : > "$STATE"
STOODDOWN="$(dirname "$STATE")/.jarvis_ios_watch_sentinel_stooddown"
emit() { echo "$1"; echo "sentinel_alert_$2" >> "$STATE"; }
arm()  { sed -i "/^sentinel_alert_$1$/d" "$STATE"; }
ALERT=0

# ---------- job record ----------
JOB_JSON=""
if [ -r "$JOBS" ]; then
  JOB_JSON=$(/usr/bin/python3 - "$JOBS" "$JOB" <<'PYEOF'
import json, sys
try:
    jobs = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
entries = jobs.get("jobs", jobs) if isinstance(jobs, dict) else jobs
entries = entries if isinstance(entries, list) else list(entries.values())
for j in entries:
    if isinstance(j, dict) and j.get("name") == sys.argv[2]:
        print(json.dumps({"enabled": j.get("enabled"),
                          "times": (j.get("repeat") or {}).get("times"),
                          "completed": (j.get("repeat") or {}).get("completed"),
                          "last_run_at": j.get("last_run_at") or ""}))
        break
PYEOF
)
fi

if [ -z "$JOB_JSON" ]; then
  # watch cron is GONE: mission-complete self-remove OR real loss.
  if ! curl -s -m 5 "$BRIDGE/health" >/dev/null 2>&1; then
    ALERT=1
    if ! grep -q '^sentinel_alert_gone$' "$STATE"; then
      emit "SENTINEL: $JOB cron is GONE and bridge :9160 is UNREACHABLE — cannot tell mission-complete from a real loss. If you did NOT just complete the ring test, the mission lost its announcer: loop agent must triage (hermes cron list | grep device-watch; curl $BRIDGE/health)." gone
    fi
    # Stand down either way: never re-warn on this condition.
    touch "$STOODDOWN"
  elif [ ! -f "$STOODDOWN" ]; then
    ALERT=1
    if ! grep -q '^sentinel_alert_gone$' "$STATE"; then
      emit "SENTINEL: $JOB cron removed while bridge :9160 is REACHABLE — if this was NOT the mission-complete self-remove, the flip announcer is lost: loop agent must triage (hermes cron list | grep device-watch)." gone
    fi
    touch "$STOODDOWN"
  fi
else
  rm -f "$STOODDOWN"
  EN=$(printf '%s' "$JOB_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("enabled"))')
  # ---------- 2. enabled ----------
  if [ "$EN" != "True" ]; then
    ALERT=1
    grep -q '^sentinel_alert_paused$' "$STATE" || \
      emit "SENTINEL: $JOB is PAUSED/disabled — the flip announcer is not running. Resume it (hermes cron resume $JOB) or install the approved replacement announcer; loop agent triages on next run." paused
  else
    arm paused
    # ---------- 3. ticks fresh (last_run_at age vs now) ----------
    LAST=$(printf '%s' "$JOB_JSON" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("last_run_at") or "")')
    if [ -n "$LAST" ]; then
      NOW=$(date -u +%s)
      LASTS=$(printf '%s' "$LAST" | /usr/bin/python3 -c 'import datetime,sys
try: print(int(datetime.datetime.fromisoformat(sys.stdin.read().strip()).timestamp()))
except Exception: print(0)')
      AGE=$(( NOW - LASTS ))
      if [ "$LASTS" -gt 0 ] && [ "$AGE" -gt 2400 ]; then
        ALERT=1
        grep -q '^sentinel_alert_stalled$' "$STATE" || \
          emit "SENTINEL: $JOB ticks STALLED — last_run_at $LAST is ${AGE}s old (>40m at a 15m cadence). The watch is enabled but not executing (scheduler down? script hang?). Loop agent triages on next run." stalled
      else
        arm stalled
      fi
    fi
    # ---------- 4. tick budget ----------
    LEFT=$(printf '%s' "$JOB_JSON" | /usr/bin/python3 -c 'import json,sys
j=json.load(sys.stdin); t,c=j.get("times"),j.get("completed")
print(t-c if isinstance(t,int) and isinstance(c,int) else "")')
    case "$LEFT" in ''|*[!0-9]*) LEFT="" ;; esac
    if [ -n "$LEFT" ] && [ "$LEFT" -le 8 ]; then
      ALERT=1
      grep -q '^sentinel_alert_budget$' "$STATE" || \
        emit "SENTINEL: $JOB has only $LEFT ticks left (~$((LEFT*15))m at 15m) — the flip announcer EXPIRES soon. Extend lifetime (hermes cron edit $JOB --repeat 384) or accept that flips after expiry announce only via the build loop." budget
    else
      arm budget
    fi
  fi
fi

# ---------- 5. bridge reachable (watch's data source) ----------
if ! curl -s -m 5 "$BRIDGE/health" | grep -q '"ok"'; then
  ALERT=1
  grep -q '^sentinel_alert_bridge$' "$STATE" || \
    emit "SENTINEL: bridge /health on :9160 UNREACHABLE or not ok — the device-watch cannot see device_registered and flips go unnoticed. Check systemd: systemctl status jarvis-ios-bridge. Loop agent triages on next run." bridge
else
  arm bridge
fi

# ---------- 6. probe still produces a verdict ----------
if [ -x "$PROBE" ] || [ -f "$PROBE" ]; then
  PV=$(/usr/bin/python3 "$PROBE" 2>/dev/null | grep -c '^VERDICT')
  if [ "$PV" -eq 0 ]; then
    ALERT=1
    grep -q '^sentinel_alert_probe$' "$STATE" || \
      emit "SENTINEL: probe_apns_delivery.py produced NO VERDICT — the watch's key-flip detection (flip 1) is blind even if the key lands. Check probe + egress to api.push.apple.com. Loop agent triages on next run." probe
  else
    arm probe
  fi
fi

# Healthy + nothing ever alerting -> silent. Success always exits 0 so the
# cron's failure channel never fires spuriously.
exit 0
