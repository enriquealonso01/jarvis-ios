"""Verify end-to-end: a native-style Bearer token now passes the voice
gateway auth gate and reaches the SDP offer handler (504/422/400 = auth OK,
handler rejects only the malformed SDP — which proves the gate passed).
"""
import base64
import hashlib
import hmac
import json
import time
import urllib.error
import urllib.request

import yaml

CFG = yaml.safe_load(open("/root/.hermes/config.yaml"))
raw = (CFG.get("dashboard") or {}).get("basic_auth", {}).get("secret", "")
secret = None
for dec in (base64.b64decode, bytes.fromhex):
    try:
        cand = dec(raw)
        if len(cand) >= 16:
            secret = cand
            break
    except Exception:
        pass
if secret is None:
    secret = raw.encode()

payload = {"sub": "enrique", "kind": "access", "exp": int(time.time()) + 600}
blob = json.dumps(payload, separators=(",", ":")).encode()
sig = hmac.new(secret, blob, hashlib.sha256).digest()
token = base64.urlsafe_b64encode(blob + sig).decode()

OFFER = "http://127.0.0.1:9150/voice-gw/api/offer"

# 1. valid bearer + garbage SDP -> expect non-401 (handler-level error)
req = urllib.request.Request(OFFER, method="POST", data=b"{}",
                             headers={"Authorization": "Bearer " + token,
                                      "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print("valid bearer:", r.status)
except urllib.error.HTTPError as e:
    print("valid bearer:", e.code, "(401 = FAIL, other = gate passed)")

# 2. bad bearer -> expect 401
req = urllib.request.Request(OFFER, method="POST", data=b"{}",
                             headers={"Authorization": "Bearer BMQAAA-invalid",
                                      "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print("invalid bearer:", r.status)
except urllib.error.HTTPError as e:
    print("invalid bearer:", e.code)

# 3. no auth -> expect 401
req = urllib.request.Request(OFFER, method="POST", data=b"{}",
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print("no auth:", r.status)
except urllib.error.HTTPError as e:
    print("no auth:", e.code)

# 4. refresh-kind token -> expect 401
p = {"sub": "enrique", "kind": "refresh", "exp": int(time.time()) + 9999}
b = json.dumps(p, separators=(",", ":")).encode()
rt = base64.urlsafe_b64encode(b + hmac.new(secret, b, hashlib.sha256).digest()).decode()
req = urllib.request.Request(OFFER, method="POST", data=b"{}",
                             headers={"Authorization": "Bearer " + rt,
                                      "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=8) as r:
        print("refresh-kind bearer:", r.status)
except urllib.error.HTTPError as e:
    print("refresh-kind bearer:", e.code)
