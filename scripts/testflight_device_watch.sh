#!/bin/bash
# jarvis-ios-device-watch — announces BOTH remaining flips of the jarvis-ios
# mission, one-shot each, then self-removes:
#   flip 1 (key):  installed APNs key becomes ACCEPTED by Apple — detected by
#                  scripts/probe_apns_delivery.py exiting 0 (verdict
#                  400 BadDeviceToken on a dummy token). This fires the moment
#                  Enrique's replacement .p8 is installed (swap_apns_key.py).
#   flip 2 (phone): bridge /health device_registered flips true — the phone
#                  completed POST /register after opening TestFlight build 1.
# Self-remove happens ONLY when BOTH bits are set (either order): key first
# then phone, or a phone that registers while the key is still bad (pushes
# would still 403) must not end the watch.
# Noise-controlled: each WAIT is printed ONCE (state-file bits); later ticks
# are silent until something flips. Read-only — GET /health plus the probe's
# dummy-token POST to Apple; no bridge state is touched.
# The self-remove failure is LOUD (manual-removal WARNING, never swallowed).
set -u
JOB=jarvis-ios-device-watch
STATE=/tmp/.jarvis_ios_device_watch_state
HERMES=/root/.local/bin/hermes
PROBE=/root/projects/jarvis-ios/scripts/probe_apns_delivery.py
BRIDGE=http://127.0.0.1:9160
[ -f "$STATE" ] || : > "$STATE"

# --- flip 1: APNs key accepted by Apple (probe exits 0 = BadDeviceToken) ---
if ! grep -q '^key_ok$' "$STATE"; then
  V=$(/usr/bin/python3 "$PROBE" 2>/dev/null | grep '^VERDICT' | head -1)
  V="${V%.}"
  if printf '%s' "$V" | grep -q "delivery path PROVEN"; then
    echo "KEY LIVE: installed APNs key is ACCEPTED by Apple (probe verdict 400 BadDeviceToken) — VoIP delivery path proven. Remaining: open TestFlight build 1 once on the phone."
    echo key_ok >> "$STATE"
  elif ! grep -q '^key_wait_announced$' "$STATE"; then
    echo "WAIT: APNs key flip pending — ${V:-probe produced no verdict}. Create the replacement key with 'APNs' CHECKED and send the .p8 (one command installs it: scripts/swap_apns_key.py)."
    echo key_wait_announced >> "$STATE"
  fi
fi

# --- flip 2: phone registered (bridge /health device_registered) ---
if ! grep -q '^device_ok$' "$STATE"; then
  H=$(curl -s -m 8 "$BRIDGE/health")
  # whitespace-tolerant: compact (real bridge) and spaced JSON both match
  if printf '%s' "$H" | grep -Eq '"device_registered":[[:space:]]*true'; then
    echo "REGISTERED: Enrique's phone completed /register — CallKit push target live. Remaining: swap in the APNs-capable key (probe must print 400 BadDeviceToken)."
    echo device_ok >> "$STATE"
  elif ! grep -q '^device_wait_announced$' "$STATE"; then
    echo "WAIT: device not registered yet — install TestFlight build 1 and open it once (reminder crons already cover this)."
    echo device_wait_announced >> "$STATE"
  fi
fi

# --- both flips seen: mission complete, self-remove (LOUD on failure) ---
if grep -q '^key_ok$' "$STATE" && grep -q '^device_ok$' "$STATE"; then
  echo "MISSION COMPLETE: APNs key accepted AND phone registered — /call now rings the phone (pushed:true). Watch standing down."
  rm -f "$STATE"
  if ! "$HERMES" cron remove "$JOB" >/dev/null 2>&1; then
    echo "WARNING: self-remove of cron '$JOB' FAILED — remove it manually: hermes cron remove $JOB"
  fi
fi
