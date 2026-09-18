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

printf '\n================\n'
if [ "$FAIL" = "0" ]; then echo "ALL GREEN"; else echo "FAILURES PRESENT"; fi
exit $FAIL
