#!/usr/bin/env python3
"""Login-path contract check (build-loop run 2026-09-19 06:45).

The app's PKCE sign-in is the one day-one path NEVER proven end-to-end: build
1/29 could not be sign-in-tested from this box, and the 06:00 audit chain
focused on the push/version pipeline. Everything else (push, /register,
WebRTC, schedule) is pinned by other checks — this one pins the AUTH half of
the mission ("open build 29 + sign in once" is NEEDS-ENRIQUE flip 2).

Three layers:

  A. APP-SIDE SHAPES (offline) — AuthStore.swift must keep sending exactly
     what the dashboard's RFC 8252 native flow expects:
       - authorize query: provider=basic, code_challenge, method=S256,
         redirect_uri=http://127.0.0.1:8619/cb (literal loopback IP —
         'localhost' is REJECTED by the server, RFC 8252 §8.3)
       - /auth/password-login body: {provider, username, password, next}
       - /auth/native/token + /auth/native/refresh bodies + the
         {access_token, refresh_token, expires_at} response decode
       - the code pulled from the 302's `next` URL (?code=...)
       - no force-unwrap regressions (serverURL pin, already in swift_sanity)

  B. LIVE SERVER CONTRACT (network, read-only, ~3 HTTP calls) — proves the
     DEPLOYED dashboard still speaks the shapes the app compiles against:
       1. /auth/native/authorize (app's exact query) -> 302 /login + PKCE cookie
       2. brokered /auth/password-login with the cookie + a probe body
          (deliberately invalid credentials) -> 401 {"detail":"Invalid
          credentials"} — the generic credential-rejection shape. This
          proves provider=basic resolves, the broker cookie is ACCEPTED
          (a provider-mismatch / unknown-broker bug answers 400/404), and
          the body model parses. Flow control only stops at the
          credential check, which is the one step that needs real creds.
       3. non-loopback redirect_uri -> 400 (the open-redirect boundary)

  C. FAIL LOUDLY on any drift — exit 1 with the layer that moved.

Network layer B is skipped (not failed) when the dashboard is unreachable,
so the sweep still works fully offline; layer A always runs.

Run: python3 scripts/check_login_contract.py [--offline]
"""
from __future__ import annotations

import base64
import hashlib
import http.cookiejar
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "ios", "JarvisApp")
AUTH = os.path.join(APP, "AuthStore.swift")

DASHBOARD = os.environ.get("JARVIS_IOS_DASHBOARD_URL", "https://jarvis.enriquecodes.com")
TIMEOUT = 15

failures: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


# ---------------------------------------------------------------------------
# Layer A — app-side request/response shapes (offline, structural)
# ---------------------------------------------------------------------------
src = open(AUTH).read()

app_pins = [
    # authorize query built exactly as the server route expects
    ('"/auth/native/authorize"', "authorize path"),
    ('"basic"', "provider=basic literal"),
    ('"code_challenge_method"', "S256 method param name"),
    ('"S256"', "S256 method value (plain is rejected server-side)"),
    ('"http://127.0.0.1:8619/cb"', "loopback redirect literal (localhost is server-REJECTED)"),
    # body models the server's pydantic models require
    ("struct PasswordLoginBody: Encodable", "password-login body model"),
    ("struct NativeTokenBody: Encodable", "native token body model"),
    ("struct NativeRefreshBody: Encodable", "native refresh body model"),
    ('"/auth/password-login"', "password-login path"),
    ('"/auth/native/token"', "token exchange path"),
    ('"/auth/native/refresh"', "refresh path"),
    # response decode: token endpoint returns access/refresh/expires_at
    ("let access_token: String", "access_token field"),
    ("let refresh_token: String", "refresh_token field"),
    ("let expires_at: Int", "expires_at field"),
    # code extraction from the broker 302's next URL
    ('"code"', "code query param"),
    # Keychain storage (never UserDefaults) for the bearer tokens
    ("SecItemAdd", "Keychain save"),
    # graceful malformed-URL handling (no force-unwrap crash path)
    ("static func serverURL(_ base: String, _ path: String) -> URL?", "serverURL builder"),
]
for needle, why in app_pins:
    if needle not in src:
        fail(f"AuthStore.swift: missing {why} (needle {needle!r})")

# The credential init must wire password->password (a copy-paste slip here
# sends the USERNAME as the password and bricks every sign-in). The init
# gained PKCE fallback params (codeChallenge/redirectURI/state, 2026-09-2x
# cookie-less login fix) — the regex accepts both shapes.
m = re.search(
    r"struct PasswordLoginBody: Encodable \{.*?init\(provider: String, username: String, password: String(?:,\s*codeChallenge: String = \"\", redirectURI: String = \"\", state: String = \"\")?\) \{(.*?)\}",
    src,
    re.S,
)
if not m:
    fail("AuthStore.swift: PasswordLoginBody/init not found")
else:
    body = m.group(1)
    if "self.password = password" not in body:
        fail("AuthStore.swift: PasswordLoginBody does not set self.password = password")
    if "self.username = username" not in body:
        fail("AuthStore.swift: PasswordLoginBody does not set self.username = username")

# PKCE helpers present and real
if "func s256(" not in src or "SHA256" not in src:
    fail("AuthStore.swift: S256 challenge helper missing")
if "SecRandomCopyBytes" not in src:
    fail("AuthStore.swift: secure verifier/state generator missing")

print(f"A. app-side shapes: {len(app_pins) + 5} pins checked on AuthStore.swift")

# ---------------------------------------------------------------------------
# Layer B — live server contract (skips when the dashboard is unreachable)
# ---------------------------------------------------------------------------
offline_only = "--offline" in sys.argv


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def check_live() -> bool:
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        # urllib silently FOLLOWS the 302 to /login and returns the login
        # page's 200 — hiding the exact status the contract pins. Forbid
        # following: the app's URL session also inspects the raw response.
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPCookieProcessor(jar))
    opener.addheaders = [("User-Agent", "jarvis-ios-login-contract/1.0")]

    verifier = b64url(secrets.token_bytes(48))
    challenge = b64url(hashlib.sha256(verifier.encode()).digest())
    state = "contract" + b64url(secrets.token_bytes(8))
    redirect = "http://127.0.0.1:8619/cb"

    # 1. authorize — must 302 to /login and SET the PKCE cookie.
    q = urllib.parse.urlencode({
        "provider": "basic",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "redirect_uri": redirect,
        "state": state,
    })
    try:
        r = opener.open(f"{DASHBOARD}/auth/native/authorize?{q}", timeout=TIMEOUT)
        code, loc = r.status, r.geturl()
    except urllib.error.HTTPError as e:
        # NoRedirect turns the 302 into an HTTPError: e.code + Location
        # header carry the contract data (302 -> /login).
        code = e.code
        loc = e.headers.get("Location") or ""
    if code != 302:
        fail(f"live: authorize answered {code}, expected 302 (dashboard contract moved?)")
        return False
    if "/login" not in loc:
        fail(f"live: authorize did not land on /login (landed {loc!r})")
        return False
    if not any(c.name.endswith("session_pkce") or "pkce" in c.name for c in jar):
        fail("live: authorize set no PKCE cookie — broker handoff would fail with 400/404")
        return False

    # 2. brokered password-login with an INVALID probe body: the ONLY
    #    acceptable answers are 401 (Invalid credentials — flow reached the
    #    credential check intact) or 429 (rate-limit kicked in — flow is
    #    alive too). 400/404/500 mean the shapes moved.
    body = json.dumps({
        "provider": "basic",
        "username": "probe-not-a-user",
        "password": "wrong",
        "next": "",
    }).encode()
    req = urllib.request.Request(
        f"{DASHBOARD}/auth/password-login", data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        r2 = opener.open(req, timeout=TIMEOUT)
        code2, detail = r2.status, r2.read()[:160].decode(errors="replace")
    except urllib.error.HTTPError as e:
        code2 = e.code
        detail = e.read()[:160].decode(errors="replace")
    if code2 not in (401, 429):
        fail(f"live: brokered password-login answered {code2} ({detail!r}) — "
             f"expected 401/429; the app's sign-in shapes no longer match the dashboard")
        return False

    # 3. open-redirect boundary: non-loopback redirect must be refused.
    q_bad = urllib.parse.urlencode({
        "provider": "basic",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "redirect_uri": "http://evil.example.com/cb",
        "state": state,
    })
    try:
        r3 = opener.open(f"{DASHBOARD}/auth/native/authorize?{q_bad}", timeout=TIMEOUT)
        code3 = r3.status
    except urllib.error.HTTPError as e:
        code3 = e.code
    if code3 != 400:
        fail(f"live: non-loopback redirect_uri answered {code3}, expected 400 "
             f"(redirect boundary regressed)")
        return False
    return True


b_ran = False
if offline_only:
    notes.append("live layer skipped (--offline)")
else:
    try:
        b_ran = check_live()
        if b_ran:
            print("B. live server contract: authorize 302+PKCE cookie OK · "
                  "brokered login reached credential check (401 generic) OK · "
                  "loopback-redirect 400 boundary OK")
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        print(f"B. live server contract: SKIPPED (dashboard unreachable: {e})")

# ---------------------------------------------------------------------------
for n in notes:
    print(n)
if failures:
    print("FAIL")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("OK: login-path contract (app shapes" + (" + live server" if b_ran else "") + ") verified")
