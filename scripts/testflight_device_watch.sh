#!/bin/bash
# jarvis-ios-device-watch — fires once when Enrique's iPhone completes its
# POST /register handshake (bridge /health device_registered flips true),
# then REMOVES ITS OWN cron job. Noise-controlled: WAIT is printed ONCE (state
# file marks it seen); every later tick is silent until the state changes.
# Read-only: GET /health only, no auth needed (public endpoint), no state touched.
set -u
JOB=jarvis-ios-device-watch
STATE=/tmp/.jarvis_ios_device_watch_state
HERMES=/root/.local/bin/hermes
H=$(curl -s -m 8 http://127.0.0.1:9160/health)
if printf '%s' "$H" | grep -q '"device_registered":true'; then
  echo "REGISTERED: Enrique's phone completed /register — VoIP pushes are live. Mission complete."
  rm -f "$STATE"
  # Loud on failure: if self-remove dies, the Ops group must know the watch
  # will keep firing (so a human removes the cron manually). Never silent.
  if ! "$HERMES" cron remove "$JOB" >/dev/null 2>&1; then
    echo "WARNING: self-remove of cron '$JOB' FAILED — remove it manually: hermes cron remove $JOB"
  fi
elif [ -f "$STATE" ]; then
  exit 0  # already announced the wait; stay quiet until something changes
else
  echo "WAIT: device not registered yet — install TestFlight build 1 and open it once (reminder crons already cover this)."
  echo wait > "$STATE"
fi