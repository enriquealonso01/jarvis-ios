#!/usr/bin/env python3
"""One-off consistency checks for the connect-deadline fix in CallManager.swift."""
import os
APP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ios", "JarvisApp")
src = open(os.path.join(APP, "CallManager.swift")).read()
checks = [
    ("waitUntilConnected call", "try await client.waitUntilConnected(timeout: 15)" in src),
    ("connectWebRTC hangs up PC before rethrow", "client.hangup()" in src),
    ("answer-fail routes into handleConnectionFailure", "self.handleConnectionFailure(error.localizedDescription)" in src),
    ("direct-call fail routes into handleConnectionFailure", "self?.handleConnectionFailure(error.localizedDescription)" in src),
    ("handleConnectionFailure clears activeCallUUID", "activeCallUUID = nil" in src.split("private func handleConnectionFailure")[1][:900]),
    ("handleConnectionFailure hangs up webRTC", "webRTC?.hangup()" in src.split("private func handleConnectionFailure")[1][:900]),
]
fail = False
for name, ok in checks:
    print(("PASS" if ok else "FAIL"), "-", name)
    fail |= not ok
if fail:
    raise SystemExit(1)
print("ALL CONSISTENCY CHECKS PASS")
