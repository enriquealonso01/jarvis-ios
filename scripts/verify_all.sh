#!/usr/bin/env bash
# verify_all.sh — one-command maintenance sweep for the jarvis-ios build loop.
# Runs every check the loop agent previously did by hand:
#   1. swift structural sanity (Swift sources, assets, project.yml)
#   2. bridge bearer-auth probe on a throwaway instance (--spawn, self-cleaning)
#   3. gateway native-bearer gate probe (live, read-only)
#   4. live health: prod bridge :9160, voice-gw :9150, public /bridge/health
# Exit 0 iff everything passes. Safe: never touches prod bridge state.
set -u
cd "$(dirname "$0")/.."
FAIL=0

step() { printf '\n=== %s ===\n' "$1"; }

step "1/4 swift_sanity"
if python3 scripts/swift_sanity.py; then :; else FAIL=1; fi

step "2/4 bridge bearer probe (throwaway :916x)"
if python3 scripts/probe_call_bearer_live.py --spawn; then :; else FAIL=1; fi

step "3/4 gateway bearer gate"
OUT=$(python3 scripts/probe_gateway_bearer_live.py 2>&1)
echo "$OUT"
# Gate: valid bearer must NOT 401; every other bearer kind must 401.
# (The probe prints '(401 = FAIL, other = gate passed)' — don't grep raw 'FAIL'.)
echo "$OUT" | grep -q 'valid bearer: 500' || { echo "GATE-FAIL: valid bearer was rejected"; FAIL=1; }
[ "$(echo "$OUT" | grep -cE '^(invalid bearer|no auth|refresh-kind bearer): 401')" = "3" ] || { echo "GATE-FAIL: bad bearers not all 401"; FAIL=1; }

step "4/4 live health"
b=$(curl -s -m 5 http://127.0.0.1:9160/health)
echo "bridge :9160  -> $b"
echo "$b" | grep -q '"ok":true' || FAIL=1
g=$(curl -s -m 5 http://127.0.0.1:9150/healthz)
echo "gateway :9150 -> $g"
echo "$g" | grep -q '"realtime":true' || FAIL=1
PUB_URL=${JARVIS_IOS_PUBLIC_HEALTH:-https://jarvis.enriquecodes.com/bridge/health}
code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "$PUB_URL")
echo "public $PUB_URL -> $code"
[ "$code" = "200" ] || FAIL=1

step "5/5 prod parity + reminder crons"
# 5a. both prod services active
for svc in jarvis-ios-bridge jarvis-voice-gateway; do
  st=$(systemctl is-active "$svc" 2>/dev/null || true)
  echo "$svc -> $st"
  [ "$st" = "active" ] || FAIL=1
done
# 5b. repo gateway mirror byte-identical to deployed gateway
if cmp -s server/voice_gateway/gateway.py /opt/voice-gw/gateway.py; then
  echo "gateway mirror byte-identical to /opt/voice-gw/gateway.py"
else
  echo "GATE-FAIL: repo gateway mirror drifted from deployed gateway"; FAIL=1
fi
# 5c. reminder crons exist and are enabled
python3 - <<'PY' || FAIL=1
import json, sys
jobs = json.load(open('/root/.hermes/cron/jobs.json'))
jobs = jobs.get('jobs', jobs) if isinstance(jobs, dict) else jobs
by_name = {j.get('name'): j for j in (jobs if isinstance(jobs, list) else jobs.values())}
ok = True
for name in ('jarvis-ios-build-loop', 'jarvis-ios-loop-sunset', 'jarvis-ios-apple-setup-guide'):
    j = by_name.get(name)
    enabled = bool(j and j.get('enabled', j.get('paused', True)) is not False)
    print(f"cron {name} -> {'armed' if enabled else 'MISSING/DISABLED'}")
    ok = ok and enabled
sys.exit(0 if ok else 1)
PY

printf '\n================\n'
if [ "$FAIL" = "0" ]; then echo "ALL GREEN"; else echo "FAILURES PRESENT"; fi
exit $FAIL
