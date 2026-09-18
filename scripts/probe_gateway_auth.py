"""Probe: does the voice gateway accept the native-app Bearer access token
on the SmallWebRTC offer endpoint, vs only the dashboard session cookie?

Writes nothing sensitive; prints only status codes.
Run: python3 scripts/probe_gateway_auth.py
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


def probe(url, headers, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, headers=headers, method=method, data=data)
    try:
        with urllib.request.urlopen(req, timeout=6) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return str(e)


OFFER = "http://127.0.0.1:9150/voice-gw/api/offer"
print("dash bearer /api/control/vitals:",
      probe("http://127.0.0.1:9119/api/control/vitals", {"Authorization": "Bearer " + token}))
print("gw bearer offer:", probe(OFFER, {"Authorization": "Bearer " + token,
                                        "Content-Type": "application/json"}, "POST", {}))
print("gw cookie offer:", probe(OFFER, {"Cookie": "hermes_session_at=" + token,
                                        "Content-Type": "application/json"}, "POST", {}))
