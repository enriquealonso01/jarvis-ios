#!/bin/bash
# jarvis-ios-device-watch — announces BOTH remaining flips of the jarvis-ios
# mission, one-shot each, then self-removes:
#   flip 1 (key):  installed APNs key becomes ACCEPTED by Apple — detected by
#                  scripts/probe_apns_delivery.py exiting 0 (verdict
#                  400 BadDeviceToken on a dummy token). This fires the moment
#                  Enrique's replacement .p8 is installed (swap_apns_key.py).
#   flip 2 (phone): bridge /health device_registered flips true — the phone
#                  completed POST /register after opening the HIGHEST build
#                  TestFlight shows (build-number agnostic on purpose; 8c).
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
    echo "KEY LIVE: installed APNs key is ACCEPTED by Apple (probe verdict 400 BadDeviceToken) — VoIP delivery path proven. Remaining: open the HIGHEST build TestFlight shows, once on the phone."
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
    echo "WAIT: device not registered yet — install JARVIS from TestFlight (the HIGHEST build number shown) and open it once."
    echo device_wait_announced >> "$STATE"
  fi
fi

# --- both flips seen: mission complete, self-remove (LOUD on failure) ---
if grep -q '^key_ok$' "$STATE" && grep -q '^device_ok$' "$STATE"; then
  # Endgame verification (dev-success-counter contract, PROGRESS 2026-09-19):
  # prove delivery with a REAL push instead of asserting it. Read push_ok
  # BEFORE, fire one verification call through the production path
  # (call_enrique.py call), re-read /health after: push_ok must have
  # incremented (accepted by Apple).
  # Note push_ok proves APNs ACCEPTED the push, not that CallKit rang the
  # phone — the ring test is still Enrique's; this only retires the bridge's
  # "did Apple take it" uncertainty. Failure here is LOUD (urgent line +
  # failure routing), and the cron stays so the loop agent can triage on its
  # next run; the state file keeps both bits so this fires once.
  H_BEFORE=$(curl -s -m 8 "$BRIDGE/health")
  # whitespace-tolerant int extraction (compact + spaced JSON both match)
  PUSH_OK_BEFORE=$(printf '%s' "$H_BEFORE" | grep -oE '"push_ok":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  CALL_OK=1
  if ! /usr/bin/python3 /root/projects/jarvis-ios/scripts/call_enrique.py call \
      --reason "JARVIS iOS verification call — this confirms calls reach your phone. Ignore/hang up." \
      --by "cron:jarvis-ios-device-watch" >/tmp/.jarvis_ios_watch_call.log 2>&1; then
    CALL_OK=0
  fi
  sleep 5
  # Re-read with retries: the bridge must be reachable AND readable, else the
  # verification cannot pass (fail-closed). Retries absorb a transient curl
  # failure right after the call POST.
  PUSH_OK_NOW=""
  for i in 1 2 3; do
    H_FINAL=$(curl -s -m 8 "$BRIDGE/health")
    PUSH_OK_NOW=$(printf '%s' "$H_FINAL" | grep -oE '"push_ok":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -n "$PUSH_OK_NOW" ] && break
    sleep 5
  done
  if [ "$CALL_OK" = 1 ] && [ -n "$PUSH_OK_NOW" ] && [ -n "$PUSH_OK_BEFORE" ] \
     && [ "$PUSH_OK_NOW" -gt "$PUSH_OK_BEFORE" ]; then
    echo "MISSION COMPLETE: APNs key accepted AND phone registered — verification push ACCEPTED by Apple (push_ok=$PUSH_OK_NOW, pushed=true). Watch standing down. One manual ring test on the phone still recommended."
    rm -f "$STATE"
    if ! "$HERMES" cron remove "$JOB" >/dev/null 2>&1; then
      echo "WARNING: self-remove of cron '$JOB' FAILED — remove it manually: hermes cron remove $JOB"
    fi
  else
    echo "URGENT: mission-complete verification FAILED (call_ok=$CALL_OK, push_ok before=$PUSH_OK_BEFORE now=${PUSH_OK_NOW:-unreadable}, health=$H_FINAL). Key+phone are live but the delivery path is NOT proven — loop agent must triage on its next run. Watch stays armed; cron NOT removed."
  fi
fi
