"""Contract tests for the bridge's approvals routes. Run: python -m pytest server/push_bridge -q

The box CLI `jarvis-approval` is replaced by a stub that records its arguments and stdin, so these
tests pin what the bridge is responsible for: who may call which route, how the phone's answer is
handed to the CLI (the pasted input on stdin, never on a command line), the status codes the app
sees, and the shape of the push.
"""
import base64
import hashlib
import hmac
import importlib
import json
import os
import sys
import time

import pytest
from fastapi.testclient import TestClient

HERE = os.path.dirname(os.path.abspath(__file__))
SECRET = "bridge-test-secret"
DASH_SECRET = b"0123456789abcdef0123456789abcdef"

STUB = r'''
import json, os, sys
args = sys.argv[1:]
log = os.environ["STUB_LOG"]
with open(log, "a", encoding="utf-8") as f:
    f.write(json.dumps({"args": args, "stdin": sys.stdin.read() if "--input-stdin" in args else None}) + "\n")
mode = os.environ.get("STUB_MODE", "ok")
if args[0] == "list":
    print(json.dumps({"ok": True, "count": 1, "pending": [{"id": "A-1001", "title": "Free product from dead channel @jamie"}], "recent": [], "key_fingerprint": "aaaa-bbbb-cccc-dddd"}))
elif args[0] == "decide":
    if mode in ("conflict", "signature", "invalid", "not_found"):
        print(json.dumps({"ok": False, "code": mode, "message": "refused: " + mode})); sys.exit(5)
    print(json.dumps({"ok": True, "repeat": mode == "repeat", "item": {"id": args[1], "state": "approved"}}))
elif args[0] == "key" and args[1] == "show":
    print(json.dumps({"ok": True, "keys": {"phone": "old0-old0-old0-old0"} if mode == "rekey" else {}}))
elif args[0] == "key" and args[1] == "set":
    print(json.dumps({"ok": True, "name": "phone", "fingerprint": "new1-new1-new1-new1"}))
else:
    print("garbage")
'''


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    cfg = tmp_path / "config.yaml"
    cfg.write_text("dashboard:\n  basic_auth:\n    username: enrique\n    secret: {}\n".format(base64.b64encode(DASH_SECRET).decode()))
    stub = tmp_path / "stub.py"
    stub.write_text(STUB)
    log = tmp_path / "stub.log"
    monkeypatch.setenv("BRIDGE_STATE_DIR", str(tmp_path))
    monkeypatch.setenv("BRIDGE_SHARED_SECRET", SECRET)
    monkeypatch.setenv("BRIDGE_DASH_CONFIG", str(cfg))
    monkeypatch.setenv("STUB_LOG", str(log))
    monkeypatch.delenv("STUB_MODE", raising=False)
    sys.path.insert(0, HERE)
    import main
    m = importlib.reload(main)
    m.APPROVAL_ARGV = [sys.executable, str(stub)]
    pushes = []
    m._send_alert = lambda payload, collapse_id="": (pushes.append((payload, collapse_id)), True)[1]

    class B:
        client = TestClient(m.app)
        module = m

        @staticmethod
        def calls():
            return [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []

        sent = pushes
    return B


def bearer(exp=None, kind="access", secret=DASH_SECRET):
    blob = json.dumps({"sub": "enrique", "kind": kind, "exp": exp or int(time.time()) + 600}, separators=(",", ":")).encode()
    return {"Authorization": "Bearer " + base64.urlsafe_b64encode(blob + hmac.new(secret, blob, hashlib.sha256).digest()).decode()}


def agent(body: bytes):
    return {"x-bridge-sig": hmac.new(SECRET.encode(), body, hashlib.sha256).hexdigest()}


def test_list_for_the_app_and_for_agents(bridge):
    r = bridge.client.get("/approvals", headers=bearer())
    assert r.status_code == 200 and r.json()["count"] == 1 and r.json()["alert_registered"] is False
    assert bridge.client.get("/approvals", headers=agent(b"")).status_code == 200
    assert bridge.client.get("/approvals").status_code == 401
    assert bridge.client.get("/approvals", headers=bearer(exp=int(time.time()) - 5)).status_code == 401


def test_decision_hands_the_signed_answer_to_the_cli_with_input_on_stdin(bridge):
    body = {"decision": "approve", "signature": "c2ln", "exp": 1800000000, "note": "  only the\nblue one ",
            "input": "http://localhost:2048/callback?code=SECRET"}
    r = bridge.client.post("/approvals/A-1001/decision", json=body, headers=bearer())
    assert r.status_code == 200 and r.json()["item"]["state"] == "approved"
    call = bridge.calls()[-1]
    assert call["args"][:3] == ["decide", "A-1001", "approve"]
    assert "--sig=c2ln" in call["args"] and "--exp=1800000000" in call["args"] and "--via=app" in call["args"]
    assert "--note=only the blue one" in call["args"]
    assert call["stdin"] == "http://localhost:2048/callback?code=SECRET"
    assert not any("SECRET" in a for a in call["args"])          # never on a command line


def test_an_agent_can_never_answer(bridge):
    raw = json.dumps({"decision": "approve", "signature": "c2ln", "exp": 1800000000}).encode()
    r = bridge.client.post("/approvals/A-1001/decision", content=raw, headers=agent(raw))
    assert r.status_code == 401
    assert bridge.client.post("/approvals/A-1001/decision", content=raw).status_code == 401
    assert bridge.client.post("/approvals/A-1001/decision", content=raw, headers=bearer(kind="refresh")).status_code == 401
    assert bridge.calls() == []


@pytest.mark.parametrize("mode,status", [("conflict", 409), ("signature", 403), ("invalid", 422), ("not_found", 404)])
def test_refusals_map_to_status_codes(bridge, monkeypatch, mode, status):
    monkeypatch.setenv("STUB_MODE", mode)
    r = bridge.client.post("/approvals/A-1001/decision", json={"decision": "deny", "signature": "x", "exp": 1}, headers=bearer())
    assert r.status_code == status and "refused" in r.json()["detail"]


def test_same_answer_twice_is_ok_and_bad_requests_never_reach_the_cli(bridge, monkeypatch):
    monkeypatch.setenv("STUB_MODE", "repeat")
    r = bridge.client.post("/approvals/1001/decision", json={"decision": "approve", "signature": "x", "exp": 1}, headers=bearer())
    assert r.status_code == 200 and r.json()["repeat"] is True
    n = len(bridge.calls())
    assert bridge.client.post("/approvals/A-1001/decision", json={"decision": "maybe"}, headers=bearer()).status_code == 422
    assert bridge.client.post("/approvals/A-1;rm/decision", json={"decision": "deny"}, headers=bearer()).status_code == 404
    assert len(bridge.calls()) == n


def test_register_alert_token_and_signing_key(bridge, monkeypatch):
    token = "ab" * 32
    r = bridge.client.post("/approvals/register", json={"alert_token": token.upper(), "signing_key": "QUJD"}, headers=bearer())
    assert r.status_code == 200 and r.json() == {"ok": True, "alert_registered": True, "key_fingerprint": "new1-new1-new1-new1"}
    assert bridge.module._load_env()["ALERT_DEVICE_TOKEN"] == token
    assert bridge.sent == []                                        # first key: nothing to announce
    assert bridge.client.get("/approvals", headers=bearer()).json()["alert_registered"] is True
    assert bridge.client.post("/approvals/register", json={"alert_token": "nothex"}, headers=bearer()).status_code == 400
    raw = json.dumps({"signing_key": "QUJD"}).encode()
    assert bridge.client.post("/approvals/register", content=raw, headers=agent(raw)).status_code == 401
    monkeypatch.setenv("STUB_MODE", "rekey")
    bridge.client.post("/approvals/register", json={"signing_key": "QUJD"}, headers=bearer())
    for _ in range(50):
        if bridge.sent:
            break
        time.sleep(0.05)
    assert bridge.sent and "signing key changed" in bridge.sent[0][0]["aps"]["alert"]["body"]


def test_notify_is_for_the_box_only_and_shapes_the_push(bridge):
    raw = json.dumps({"event": "new", "id": "A-1001", "title": "Krendora", "body": "Free product from dead channel @jamie", "badge": 3}).encode()
    assert bridge.client.post("/approvals/notify", content=raw, headers=bearer()).status_code == 401
    r = bridge.client.post("/approvals/notify", content=raw, headers=agent(raw))
    assert r.status_code == 200 and r.json() == {"ok": True, "pushed": True}
    payload, collapse = bridge.sent[-1]
    assert payload["aps"]["alert"] == {"title": "Krendora", "body": "Free product from dead channel @jamie"}
    assert payload["aps"]["badge"] == 3 and payload["aps"]["sound"] == "default" and collapse == ""
    assert payload["jarvis"] == {"kind": "approval", "event": "new", "id": "A-1001"}
    raw = json.dumps({"event": "badge", "badge": 0}).encode()
    bridge.client.post("/approvals/notify", content=raw, headers=agent(raw))
    payload, collapse = bridge.sent[-1]
    assert payload["aps"] == {"badge": 0} and collapse == "jarvis-approvals-badge"   # badge only: no banner, no sound
