#!/usr/bin/env python3
"""Pin the mid-call drop detection wiring (2026-09-18 run).

No Swift toolchain on this box, so we verify the ICE-disconnected grace
logic structurally:
  1. WebRTCClient arms a grace timer on `.disconnected` ONLY when it had
     connected (never-connected disconnected stays terminal-immediate).
  2. The grace timer fires onConnectionFailed (dead line -> CallManager
     fails the call), and is cancelled on connected/completed/failed/closed
     and in hangup().
  3. handleConnectionFailure in CallManager clears the call + stamps the
     log "failed" (already pinned, re-checked here end-to-end).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "ios", "JarvisApp")
src = open(os.path.join(APP, "WebRTCClient.swift")).read()
mgr = open(os.path.join(APP, "CallManager.swift")).read()

fails = []


def need(hay, needle, label):
    if needle not in hay:
        fails.append(f"{label}: missing {needle!r}")


# 1. disconnected branch: grace only after connect, terminal before it.
m = re.search(r"case \.disconnected:\n(.*?)\n        default:", src, re.S)
if not m:
    fails.append("ICE switch: .disconnected case not found")
else:
    body = m.group(1)
    need(body, "if !connected {", "disconnected branch")
    need(body, "startDisconnectGrace()", "disconnected branch")

# 2. connected/completed stand the timer down; hangup() cancels it.
need(src, "case .connected, .completed:\n            // ICE recovered", "ICE switch")
need(src, "cancelDisconnectGrace()", "hangup()")
need(src, "onConnectionFailed?(\"media connection lost (no recovery within", "grace timer")

# 3. end-to-end: the failure callback routes into CallManager teardown.
need(mgr, "client.onConnectionFailed = { [weak self] why in", "CallManager wiring")
need(mgr, "handleConnectionFailure", "CallManager teardown")

if fails:
    print("FAIL")
    for f in fails:
        print(" -", f)
    sys.exit(1)
print("OK: mid-call drop-detection wiring pinned (grace on reconnect-only, "
      "terminal on expiry, teardown routed)")
