#!/usr/bin/env bash
# selftest_ship_gate.sh — negative-tests ship_gate.py in a THROWAWAY clone.
# The real tree is never touched (the gate itself is read-only anyway; the
# clone exists so LOCAL TAG STATE can be mutated safely). Proves the gate
# fails LOUDLY, with the right reason, on:
#   T1  a local-only ios-v* tag (the 12:05 failure class — tag never pushed)
#   T3  a RED Actions run for the latest tag (must NOT read as shipped)
#   T4  an unreadable GitHub credential (loud config failure, no traceback)
# (T2 — origin lists the tag but lacks its commit — is impossible for refs:
# ls-remote only lists refs whose tip it can serve, so T1 covers the class.)
# Exit 0 iff every negative test bit. Run time ~15s (2 real API calls).
set -u
cd "$(dirname "$0")/.."
REAL=$PWD
FAIL=0

expect_fail() { # label, expected needle, then command...
  local label="$1" needle="$2"; shift 2
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "FAIL $label: gate PASSED but should have failed"
    echo "$out" | head -4
    FAIL=1
  elif ! grep -q "$needle" <<<"$out"; then
    echo "FAIL $label: gate failed (rc=$rc) but without the expected reason"
    echo "$out" | head -4
    FAIL=1
  else
    echo "PASS $label: $(grep -m1 "$needle" <<<"$out" | head -c 110)"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# throwaway clone of the real repo; same origin URL (the gate reads the
# CLONE's tags via git, and origin's tags via the network)
git clone -q --no-hardlinks "$REAL" "$TMP/clone"
git -C "$TMP/clone" remote set-url origin \
  "https://github.com/enriquealonso01/jarvis-ios.git"
CLONE=$TMP/clone

# each negative test runs with a throwaway HOME (so credential state is
# controllable per-test); seed it with a COPY of the real credential file —
# git needs it for ls-remote auth, and it lives only in $TMP (never git)
GOODHOME=$TMP/home
mkdir -p "$GOODHOME"
# BOTH files are load-bearing: .gitconfig points git at the store helper,
# .git-credentials holds the token. Copy both.
cp "${REAL_GIT_CRED:-$HOME/.git-credentials}" "$GOODHOME/.git-credentials"
cp "$HOME/.gitconfig" "$GOODHOME/.gitconfig" 2>/dev/null || \
  git config --global --file "$GOODHOME/.gitconfig" credential.helper store
chmod 600 "$GOODHOME/.git-credentials"

# T1: latest LOCAL tag does not exist on origin
git -C "$CLONE" tag ios-v99999
( cd "$CLONE" && HOME="$GOODHOME" expect_fail "T1 local-only tag" \
  "NOT on origin" python3 "$REAL/scripts/ship_gate.py" --skip-asc )
git -C "$CLONE" tag -d ios-v99999 >/dev/null

# T3: latest local tag is one whose newest push Actions run went RED. The
# gate reads the NEWEST run for the tag, so the pin needs a tag whose latest
# run failed: ios-v26 (run 28, failure 2026-09-19 — real historical data,
# no way to fabricate a run). ios-v27..v31 all went green, so they're
# deleted to make ios-v26 the latest local tag.
git -C "$CLONE" tag -d ios-v31 >/dev/null 2>&1
git -C "$CLONE" tag -d ios-v30 >/dev/null 2>&1
git -C "$CLONE" tag -d ios-v29 >/dev/null 2>&1
git -C "$CLONE" tag -d ios-v28 >/dev/null 2>&1
git -C "$CLONE" tag -d ios-v27 >/dev/null 2>&1
( cd "$CLONE" && HOME="$GOODHOME" expect_fail "T3 red run for latest tag" \
  "concluded failure" python3 "$REAL/scripts/ship_gate.py" --skip-asc )
git -C "$CLONE" tag ios-v27 >/dev/null 2>&1 || true
git -C "$CLONE" tag ios-v28 >/dev/null 2>&1 || true
git -C "$CLONE" tag ios-v29 >/dev/null 2>&1 || true
git -C "$CLONE" tag ios-v30 >/dev/null 2>&1 || true

# T4: unreadable credential -> loud config failure before any API call
TMPHOME=$(mktemp -d)
( cd "$CLONE" && HOME="$TMPHOME" expect_fail "T4 bad credential" \
  "credential" python3 "$REAL/scripts/ship_gate.py" --skip-asc )
rm -rf "$TMPHOME"

exit $FAIL
