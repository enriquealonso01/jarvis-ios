"""probe_webrtc_native.py — END-TO-END native-client WebRTC smoke test.

Everything before this verified the AUTH GATE only (valid bearer -> 500 on
/voice-gw/api/offer). This probe does the real thing the iOS app does:

  1. mint a dashboard access Bearer (same token shape as the app's),
  2. POST a real SDP offer (aiortc) to /voice-gw/api/offer with
     request_data {surface:"ios", reason:"..."},
  3. apply the gateway's answer -> ICE connect (STUN loopback),
  4. open the ordered "app" data channel, send literal "ping" at 1 Hz,
  5. assert the gateway's session UI arrives: hello (thread/brain) and/or
     state/transcript messages, exactly as voice_page.html consumes them.

PASS = answer 200 + connection established + >=1 gateway UI message on the
data channel within the window. READ-ONLY to prod: one throwaway session that
hangs up at the end. It never touches bridge state or the dashboard.

Run:  /root/venvs/webrtc-probe/bin/python scripts/probe_webrtc_native.py
Deps: aiortc (isolated venv /root/venvs/webrtc-probe; heavy native build —
      intentionally NOT in the system interpreter).
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import sys
import time
import urllib.error
import urllib.request
import yaml

PROBE_TIMEOUT = 45.0  # seconds: offer -> answer -> ICE -> hello


def _dash_secret_bytes() -> bytes:
    cfg = yaml.safe_load(open("/root/.hermes/config.yaml"))
    raw = (cfg.get("dashboard") or {}).get("basic_auth", {}).get("secret", "")
    for dec in (base64.b64decode, bytes.fromhex):
        try:
            cand = dec(raw)
            if len(cand) >= 16:
                return cand
        except Exception:
            continue
    return raw.encode()


def mint_token(kind: str = "access", ttl: int = 600) -> str:
    payload = {"sub": "webrtc-probe", "kind": kind, "exp": int(time.time()) + ttl}
    blob = json.dumps(payload, separators=(",", ":")).encode()
    sig = hmac.new(_dash_secret_bytes(), blob, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(blob + sig).decode()


def post_offer(url: str, body: dict, token: str):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:300]


async def run(base: str, reason: str) -> int:
    from aiortc import RTCPeerConnection, RTCSessionDescription, RTCConfiguration

    token = mint_token()
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))  # host candidates only
    got: dict = {"hello": False, "any_ui": False, "track": False}
    done = asyncio.Event()

    # Audio: we only ever PLAY the gateway's audio (the probe has no mic), so a
    # recvonly transceiver makes the gateway answer with its outbound audio
    # track — what the iOS app's speaker plays.
    pc.addTransceiver("audio", direction="recvonly")

    @pc.on("track")
    def _track(track):
        got["track"] = True
        print(f"[probe] inbound track: {track.kind}")

    @pc.on("datachannel")
    def _dc(channel):
        print(f"[probe] gateway created datachannel: {channel.label}")
        _pump(channel)

    def _pump(channel):
        @channel.on("message")
        def _msg(message):
            got["any_ui"] = True
            try:
                msg = json.loads(message) if isinstance(message, str) else {}
            except Exception:
                msg = {}
            if msg.get("type") == "hello":
                got["hello"] = True
                print(f"[probe] hello: thread={msg.get('thread')!r} brain={msg.get('brain')!r}")
            elif msg.get("type") in ("state", "transcript", "metrics", "interim"):
                print(f"[probe] ui: {str(msg)[:120]}")

    # The client creates the "app" channel (same as voice_page.html / the iOS
    # app) and keeps it alive with 1 Hz literal "ping" frames.
    channel = pc.createDataChannel("app", ordered=True)
    _pump(channel)

    @channel.on("open")
    def _open():
        print("[probe] app datachannel open; pinging at 1 Hz")

    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    body = {
        "sdp": pc.localDescription.sdp,
        "type": pc.localDescription.type,
        "pc_id": "webrtc-probe",
        "request_data": {"surface": "ios", "reason": reason},
    }

    pc_id = None
    session = None

    async def pinger():
        while not done.is_set():
            try:
                channel.send("ping")
            except Exception:
                return
            await asyncio.sleep(1.0)

    status, answer = post_offer(base + "/voice-gw/api/offer", body, token)
    print(f"[probe] offer -> {status}")
    if status != 200 or not isinstance(answer, dict):
        print("FAIL offer rejected:", answer)
        await pc.close()
        return 1
    print(f"[probe] answer type={answer.get('type')} "
          f"pc_id={answer.get('pc_id')!r}")
    pc_id = answer.get("pc_id")

    await pc.setRemoteDescription(RTCSessionDescription(
        sdp=answer["sdp"], type=answer["type"]))
    pinger_task = asyncio.create_task(pinger())

    # Wait for ICE connection + gateway hello/state + the audio track.
    deadline = time.time() + PROBE_TIMEOUT
    while time.time() < deadline:
        st = pc.connectionState
        if st in ("failed", "closed"):
            print(f"FAIL peer connection state={st}")
            break
        if got["any_ui"] and got["track"] and st == "connected":
            break
        await asyncio.sleep(0.5)

    hangup = {"ok": False}
    try:
        hreq = urllib.request.Request(
            base + "/voice-gw/api/hangup",
            data=json.dumps({"pc_id": pc_id}).encode(), method="POST",
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(hreq, timeout=8) as r:
            hangup = json.loads(r.read().decode())
    except Exception as e:
        print(f"[probe] hangup: {e}")

    done.set()
    pinger_task.cancel()
    await pc.close()

    ok = got["any_ui"] and got["track"]
    print(f"[probe] connected={pc.connectionState} track={got['track']} "
          f"hello={got['hello']} any_ui={got['any_ui']} hangup={hangup}")
    print("PASS native WebRTC e2e" if ok else "FAIL native WebRTC e2e")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:9150")
    ap.add_argument("--reason", default="build-loop native WebRTC probe")
    a = ap.parse_args()
    try:
        raise SystemExit(asyncio.run(run(a.base, a.reason)))
    except ImportError as e:
        print(f"FAIL aiortc unavailable: {e}\n"
              f"setup: python3 -m venv /root/venvs/webrtc-probe && "
              f"/root/venvs/webrtc-probe/bin/pip install aiortc")
        raise SystemExit(2)


if __name__ == "__main__":
    main()
