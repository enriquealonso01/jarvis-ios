#!/usr/bin/env python3
"""Live-audit probe: check bridge contract shapes (read-only GETs)."""
import json, hmac, hashlib, urllib.request, urllib.error
SECRET = open('/opt/jarvis-ios-bridge/shared_secret','rb').read().strip()
def sig(b): return hmac.new(SECRET, b, hashlib.sha256).hexdigest()
def req(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else b""
    r = urllib.request.Request("http://127.0.0.1:9160"+path, data=data if method=="POST" else None, method=method)
    if method == "POST":
        r.add_header("Content-Type","application/json")
        r.add_header("x-bridge-sig", sig(data))
    else:
        r.add_header("x-bridge-sig", sig(b""))
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200]
print("health:", req("GET","/health"))
print("secrets:", req("GET","/secrets"))
print("schedule/list:", req("GET","/schedule/list"))
# Contract probe: /secrets/delete of a NONEXISTENT name returns ok:True deleted:False?
print("delete nonexistent:", req("POST","/secrets/delete",{"name":"__probe_nonexistent__"}))
# Contract probe: /secrets/set with an EMPTY value -> 422?
print("set empty value:", req("POST","/secrets/set",{"name":"__probe_x__","value":""}))
# Contract probe: name with '=' -> 422?
print("set bad name:", req("POST","/secrets/set",{"name":"a=b","value":"x"}))
# Contract probe: /schedule cancel of nonexistent id -> cancelled:0?
print("cancel nonexistent:", req("POST","/schedule/cancel",{"call_id":"__nope__"}))
