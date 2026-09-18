"""Patch gateway.py auth gate: accept native-app Bearer access tokens.

The iOS app authenticates to the dashboard with an RFC 8252 Bearer access
token (HMAC-signed by dashboard.basic_auth.secret — the same stateless token
shape the gateway already mints for itself in _mint_session_token). The
gateway's auth gate only looked at session cookies, so native clients got 401
on /voice-gw/api/offer.

This patch adds a local Bearer verify path to _cookie_valid's caller chain:
extract bearer -> verify kind=access + exp against _BA secret -> same
auth-cache. No dashboard round-trip needed (we hold the signing secret).

Applied by the jarvis-ios loop agent 2026-09-18. py_compile gate + healthz
check per rules. Backup: /root/voice-gw-backup-20260918-025349.py
"""
import re

P = "/opt/voice-gw/gateway.py"
src = open(P, newline="").read()
orig = src

# 1. Add a bearer extractor + verifier next to _cookie_from/_cookie_valid.
anchor = "async def _cookie_valid(token: str) -> bool:\r\n"
assert anchor in src, "anchor _cookie_valid missing"

bearer_block = (
    "\r\n"
    "\r\ndef _bearer_from(request: \"Request\") -> Optional[str]:\r\n"
    "    # Native (iOS) clients authenticate with the SAME stateless HMAC\r\n"
    "    # access token the dashboard's basic provider mints (RFC 8252 flow):\r\n"
    "    # Authorization: Bearer <token>. Verify locally — we already hold\r\n"
    "    # the signing secret for _mint_session_token, so no dashboard\r\n"
    "    # round-trip is needed. Same trust domain as the cookie path.\r\n"
    "    auth = request.headers.get(\"authorization\", \"\")\r\n"
    "    parts = auth.split(\" \", 1)\r\n"
    "    if len(parts) != 2 or parts[0].strip().lower() != \"bearer\":\r\n"
    "        return None\r\n"
    "    return parts[1].strip() or None\r\n"
    "\r\n"
    "\r\n"
    "def _bearer_valid(token: str) -> bool:\r\n"
    "    # Verify kind=access + exp exactly like the basic provider's\r\n"
    "    # verify_session: unsign (urlsafe b64 of json+sig), check exp.\r\n"
    "    try:\r\n"
    "        blob = base64.urlsafe_b64decode(token.encode())\r\n"
    "        if len(blob) <= 32:\r\n"
    "            return False\r\n"
    "        raw, sig = blob[:-32], blob[-32:]\r\n"
    "        if not hmac_mod.compare_digest(sig, hmac_mod.new(_secret_bytes(), raw, hashlib.sha256).digest()):\r\n"
    "            return False\r\n"
    "        payload = json.loads(raw)\r\n"
    "        return payload.get(\"kind\") == \"access\" and payload.get(\"exp\", 0) > int(time.time())\r\n"
    "    except Exception:\r\n"
    "        return False\r\n"
    "\r\n"
    "\r\n"
    "def _secret_bytes() -> bytes:\r\n"
    "    # Same decode ladder as _mint_session_token.\r\n"
    "    raw = _BA.get(\"secret\", \"\")\r\n"
    "    for decoder in (base64.b64decode, bytes.fromhex):\r\n"
    "        try:\r\n"
    "            cand = decoder(raw)\r\n"
    "            if len(cand) >= 16:\r\n"
    "                return cand\r\n"
    "        except Exception:\r\n"
    "            continue\r\n"
    "    return raw.encode()\r\n"
)

src = src.replace(anchor, bearer_block + "\r\n" + anchor, 1)

# 2. Extend the auth-gate middleware to try bearer before failing.
gate_old = (
    "    token = _cookie_from(request)\r\n"
    "    if token and await _cookie_valid(token):\r\n"
    "        return await call_next(request)\r\n"
)
gate_new = (
    "    token = _cookie_from(request)\r\n"
    "    if token and await _cookie_valid(token):\r\n"
    "        return await call_next(request)\r\n"
    "    # Native-app bearer path (iOS): same HMAC token, no cookie.\r\n"
    "    bearer = _bearer_from(request)\r\n"
    "    if bearer and _bearer_valid(bearer):\r\n"
    "        return await call_next(request)\r\n"
)
assert gate_old in src, "auth gate anchor missing"
src = src.replace(gate_old, gate_new, 1)

assert src != orig
open(P, "w", newline="").write(src)
print("patched OK")
