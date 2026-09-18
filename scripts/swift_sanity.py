#!/usr/bin/env python3
"""Sanity checks for jarvis-ios Swift sources (backlog #9).

No Swift toolchain on this box, so we verify structural things agents can
break: balanced braces/parens per file, required symbols present, and that
Assets.xcassets JSON files all parse. Run: python3 scripts/swift_sanity.py
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "ios", "JarvisApp")

failures = []

# 1. brace/paren/bracket balance per Swift file (strings/comments ignored —
#    good enough for structural drift detection).
for fn in sorted(os.listdir(APP)):
    if not fn.endswith(".swift"):
        continue
    src = open(os.path.join(APP, fn)).read()
    # strip line comments and string literals crudely to avoid false counts
    cleaned = []
    in_str = in_line_comment = False
    i = 0
    while i < len(src):
        c = src[i]
        if in_line_comment:
            if c == "\n":
                in_line_comment = False
                cleaned.append(c)
        elif in_str:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "/" and i + 1 < len(src) and src[i + 1] == "/":
                in_line_comment = True
            else:
                cleaned.append(c)
        i += 1
    s = "".join(cleaned)
    for open_c, close_c, name in [("{", "}", "braces"), ("(", ")", "parens"), ("[", "]", "brackets")]:
        bal = s.count(open_c) - s.count(close_c)
        if bal != 0:
            failures.append(f"{fn}: unbalanced {name} ({bal:+d})")

# 2. required symbols across the app.
required = {
    "Haptics.swift": ["enum Haptics", "static func success", "static func tap"],
    "AuthViews.swift": ["applyManualToken", "testConnection", "faceIDLock", "SettingsView"],
    "AuthStore.swift": ["func applyManualToken"],
    "SecretsView.swift": ["lockedView", "LAContext", "secretsList"],
    "JarvisApp.swift": ["RootTabView", "GlassCard", "glassEffect"],
    "CallLogStore.swift": ["final class CallLogStore", "struct Entry: Codable", "func add(reason", "func finish(id:", "outcome", "durationSeconds"],
    "CCClient.swift": ["struct Attention", "struct WorkHistory"],
    "HomeView.swift": ["alertsCard", "Attention"],
    "WebRTCClient.swift": ["startDisconnectGrace", "cancelDisconnectGrace", "disconnectGraceSeconds", "no recovery within"],
    "ChatsView.swift": ["NewTaskSheet", "project/task", "lastMessage", "pollHistory", "decodedLines", "JARVIS is thinking",
                        # pollHistory compares [ChatLine] with != — without Equatable
                        # that line is a hard Xcode build error.
                        "struct ChatLine: Identifiable, Equatable"],
    "CallManager.swift": ["trackOutgoingLog", "logEntryID", "outcome", "placeDirectCall", "CXStartCallAction", "setupCallUI", "dialing", "handleConnectionFailure",
                          # PushKit contract: completion is resolved by the
                          # incoming-call report handler, never inline.
                          "onReported: completion", "onReported?()"],
    "CallsView.swift": ["durationSeconds", "outcome", "trackOutgoingLog", "Talk to JARVIS", "placeDirectCall", "ScheduleCallSheet", "scheduleCall(at:", "/schedule", "whenLabel"],
}
for fn, syms in required.items():
    path = os.path.join(APP, fn)
    if not os.path.exists(path):
        failures.append(f"missing file: {fn}")
        continue
    src = open(path).read()
    for sym in syms:
        if sym not in src:
            failures.append(f"{fn}: missing symbol {sym}")

# 2b. duplicate top-level type declarations across the whole target — Swift
#     rejects a redeclared type at module scope, and a rename that misses one
#     declaration would only surface as a hard Xcode build error.
import re
decl_re = re.compile(r"^(?:@\w+\s+)*(?:public |private |fileprivate |internal |final |open )*"
                     r"(?:class|struct|enum|actor|protocol)\s+([A-Za-z_]\w*)", re.M)
owners = {}
for fn in sorted(os.listdir(APP)):
    if not fn.endswith(".swift"):
        continue
    src = open(os.path.join(APP, fn)).read()
    for m in decl_re.finditer(src):
        owners.setdefault(m.group(1), []).append(fn)
for name, fns in sorted(owners.items()):
    if len(fns) > 1:
        failures.append(f"duplicate top-level type '{name}' declared in: {', '.join(fns)}")

# 2c. known-hazard patterns (each caused or risks a real Xcode build error).
hazards = [
    # CXProvider has no reportCall(with:endedAt:reason:) — reason-only variant
    # is for remote reports; our local end uses endedAt only.
    ("reportCall(with: endedAt: reason:", "nonexistent CXProvider API"),
    # unavailable / availability-gated Foundation init shadowing risk
    ("URLRequest(url: url, method:", "ambiguous/shadowed URLRequest init"),
    # CallManager: the CXProvider property is `provider`; a bare `prov.` at
    # class scope (leftover local rename from setupCallUI) is a hard
    # "cannot find 'prov' in scope" Xcode error on the incoming-call path.
    # Only the wiring inside setupCallUI() is legitimate — it assigns the
    # property right after, so pin on the assignment being present instead.
    ("prov.reportNewIncomingCall", "undefined 'prov' — use the 'provider' property"),
    # CallManager: APNs is at-least-once + bridge retries — handleVoIPPayload
    # MUST guard a re-delivered call_id (same-call dedupe) or a duplicate push
    # stacks a second CallKit report and corrupts the call log (PROGRESS
    # 2026-09-18 11:05). This is a MUST-CONTAIN pin (see required_guard_pins),
    # not a hazard needle — the needle IS the guard.
]
# MUST-CONTAIN pins: needle must be PRESENT in the file or it's a failure
# (the guard above protects against the needle appearing; these protect
# against it disappearing).
required_guard_pins = [
    ("CallManager.swift", ["pendingAnswerPayload?.callID == p.callID"]),
    # Device-token /register must retry (fresh install: push token arrives
    # before login, so the first attempt 401s) — a revert to the fire-and-
    # forget single POST leaves "ring this phone" dead until next launch.
    ("CallManager.swift", ["for attempt in 0..<5"]),
    # HomeView per-endpoint resilience: load1 + try? keeps one failing CC
    # endpoint from blanking the whole Home tab (all-or-nothing tuple throw).
    ("HomeView.swift", ["try? load1", "vitals = v2 ?? vitals"]),
    # HomeView gateway dot must reflect real bridge reachability — a hardcoded
    # .green Circle() lies when the dashboard can't reach the gateway.
    ("HomeView.swift", ["gatewayOK ? .green : .red"]),
    # Chats poll identity: ChatLine.id must be CONTENT-derived. A `let id =
    # UUID()` field makes the 5s pollHistory compare unequal every tick and
    # re-create every bubble (flicker + scroll jump).
    ("ChatsView.swift", ["var id: String { role + \"|\" + text }"]),
]
for fn in sorted(os.listdir(APP)):
    if not fn.endswith(".swift"):
        continue
    src = open(os.path.join(APP, fn)).read()
    for needle, why in hazards:
        if needle in src:
            failures.append(f"{fn}: hazard pattern '{needle}' ({why})")
for fn, needles in required_guard_pins:
    path = os.path.join(APP, fn)
    if not os.path.exists(path):
        failures.append(f"missing file: {fn}")
        continue
    src = open(path).read()
    for needle in needles:
        if needle not in src:
            failures.append(f"{fn}: REQUIRED pin missing '{needle}' (guard was removed)")

# 3. asset catalog JSON validity + required entries.
assets = os.path.join(APP, "Assets.xcassets")
for root, _, files in os.walk(assets):
    for f in files:
        if f.endswith(".json"):
            try:
                json.load(open(os.path.join(root, f)))
            except Exception as e:
                failures.append(f"bad asset JSON {os.path.relpath(os.path.join(root, f), ROOT)}: {e}")

for entry in ["AppIcon.appiconset/icon-1024.png", "LaunchReactor.imageset/launch-reactor.png",
              "LaunchBackground.colorset/Contents.json", "AccentColor.colorset/Contents.json"]:
    if not os.path.exists(os.path.join(assets, entry)):
        failures.append(f"missing asset: {entry}")

# 4. project.yml wiring.
pyml = open(os.path.join(ROOT, "ios", "project.yml")).read()
for needle in ["ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon",
               "UILaunchScreen:", "UIColorName: LaunchBackground", "UIImageName: LaunchReactor"]:
    if needle not in pyml:
        failures.append(f"project.yml missing: {needle}")

if failures:
    print("FAIL")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("OK: swift structural + asset + project.yml checks passed")
