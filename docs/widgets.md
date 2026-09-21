# JARVIS iOS — Widgets: Research & Implementation Plan (Feedback Round 2, item 5)

**Status:** SHIPPED 2026-09-21 — extension target live, three widgets riding build 40+.
(Original plan below, kept for the design record; the "deferred" decision was
overridden when Enrique asked for the widgets directly.)

## Shipped implementation (2026-09-21)

- **Target:** `JarvisWidgets` (xcodegen `app-extension`), bundle
  `com.enriquecodes.jarvis.Widgets`, embedded via the app's `dependencies: - target: JarvisWidgets`.
- **Widgets** (WidgetKit, `StaticConfiguration`, shared `SnapshotProvider`):
  1. *JARVIS Status* — small (gateway dot, CPU/MEM/DISK) + medium (adds Current Work + Sessions/Calls quick links).
  2. *JARVIS Metrics* — small (top LLM window + crons line) + medium (all LLM windows + crons).
  3. *JARVIS Attention* — small (count + top alert, All-clear state) + medium (top 3 alerts).
- **Data path:** Path A as planned — app publishes a CC snapshot into the App Group
  (`UserDefaults(suiteName: "group.com.enriquecodes.jarvis")`) on every Home refresh
  (`WidgetBridge.sync`) and mirrors bearer/refresh tokens (`WidgetBridge.publishAuth`);
  the extension reads the cache AND can refresh live via the dashboard API itself
  (`WidgetAPI.fetchLive`), falling back to the cache offline. NOTE: the group is
  `group.com.enriquecodes.jarvis` — the `.shared` suffix reserved in the original
  plan below was NOT used; both entitlements files are the source of truth.
- **Cadence:** timeline `.after(+20min)` (above WidgetKit's ~15min floor); app re-kicks
  `WidgetCenter.reloadAllTimelines()` on every Home refresh. Budget stays well under
  the ~40-70 reloads/day window.
- **Deep links:** `jarvis://sessions|calls|more|status` via `.widgetURL` + `onOpenURL`
  tab switching in `RootTabView`; scheme registered in project.yml (`CFBundleURLTypes`).
- **Apple-side registration:** bundle ID created + `APP_GROUPS` capability enabled on
  BOTH bundle IDs via ASC API `POST /v1/bundleIdCapabilities` (note: enum is
  `APP_GROUPS`; `GROUP_CONTAINER` is invalid; `/v1/appGroups` does NOT exist — 404).
  The group record + attach = `ensure_widget_portal` lane (fastlane `produce group` /
  `associate_group`, idempotent, runs before every archive); match runs per-target with
  `force: true` so profiles carry the new entitlement.
- **Limitations:** widgets show cached data until the app has logged in once on-device
  (tokens live in the Keychain; the group container gets them at first login/refresh);
  no push-to-refresh yet (needs the APNs-capable key, same blocker as VoIP — Path B
  later); lock-screen accessory families not yet built; extension cannot exceed the
  ~20min self-refresh floor regardless of API health.

---

## Original plan (2026-09-21, feedback round 2)

---

## 1. What Enrique wants (the actual ask)

> "JARVIS to CREATE iOS widgets on demand later (example: 25 IG accounts as green/yellow/red circles for his Shopify store)."

This is **not** "build the IG widget now." It is: make sure the JARVIS iOS app can
**host user-facing widgets later without another surgery project**, and that the
hard part (App Group + data path + scaffold) is ready when the ask lands.

## 2. Research summary (verified against Apple docs + WWDC26 "WidgetKit foundations", 2026-09-21)

| Topic | Finding (verified) |
|---|---|
| Framework | WidgetKit (not SwiftUI's older `DKWidgetKit`, not `IntentsUI`). Confirmed modern approach. |
| Extension | A **Widget Extension target** (app extension) must be added to `JarvisApp.xcodeproj`. |
| Modern config | **App Intents** (`WidgetConfigurationIntent` + `AppIntentTimelineProvider`) — SiriKit `IntentConfiguration` is legacy (pre-iOS 17); for min target iOS 18 we go straight App-Intents. |
| Config UI | Free UI from `@Parameter` on the intent; `AppEnum` / `AppEntity` give dynamic pickers. |
| Sizes | `WidgetFamily`: `systemSmall/Medium/Large`, `accessoryCircular/Rectangular/Inline` (lock screen), `accessoryCircular` fits the green/yellow/red circles idea perfectly. |
| Timelines | `Timeline(entries:policy:)` — `.after(date)` preferred over `.atEnd` (predictable, protects refresh budget ~40-70 reloads/day). |
| Interactive widgets | iOS 17+: `Button`/`Toggle` inside widget via App Intents `perform()` — runs in extension process. |
| Push-to-refresh | `WidgetCenter.shared.reloadTimelines(ofKind:)` (app) or `WidgetPushHandler` (server push → widget reload). |
| Data sharing | **App Group** (`UserDefaults(suiteName:)` or shared file container) is the standard app↔extension channel. |
| Deep links | `.widgetURL(_:)` for tap-through. |

### Key architectural conclusion for JARVIS

The 25-IG-account circles widget is **server-driven state** (account health lives on
the krendora/IG tooling side, not in the phone). Widget timelines are **static
snapshots** refreshed on a budget. Two viable data paths:

- **Path A — App-Group snapshot (recommended start):** the main app (or a bridge
  endpoint the app polls) writes a JSON snapshot into the shared App Group
  container; the widget extension reads it in `getTimeline`. Zero server work;
  refresh cadence = timeline policy.
- **Path B — WidgetKit push (`WidgetPushHandler`):** server pushes a content-state
  payload + `widget-reload` token; instant updates without app launch. Requires
  APNs with `pushType=widget` (same APNs-key blocker as VoIP today).

Recommendation: **start Path A** (works today, no server change), migrate to Path B
once the APNs-capable key is in (it unblocks both CallKit background calls and
widget push reloads in one shot).

## 3. Scaffold status (what's already in the repo)

| Piece | Status |
|---|---|
| Plan + signing recipe (§4) | ✅ this file |
| App Group `group.com.enriquecodes.jarvis.shared` | 📝 NAME RESERVED + documented in `ios/project.yml` — deliberately NOT yet in `JarvisApp.entitlements`. Adding the `application-groups` entitlement before the capability exists on the App ID would make every readonly-match archive fail codesign ("profile does not include application-groups"). It gets added in the SAME step as the extension (§4.1 bootstrap re-run), so the app build is never at risk. |
| Widget extension target in `project.yml` | ⏸ deferred (see §6) |
| `WidgetKit` code (timeline provider, views) | ⏸ deferred (no extension target to compile it in yet) |

## 4. When we build it — exact steps (paste-ready for future agent)

### 4.1 Capability + signing (once, via ASC API or match)

1. Register the App Group `group.com.enriquecodes.jarvis.shared` on the App ID via
   ASC API (`POST /v1/bundleIdCapabilities`, type `GROUP_CONTAINER`), or let match
   do it during `bootstrap_signing readonly:false`.
2. Delete the stale `match AppStore com.enriquecodes.jarvis` profile; re-run
   `bootstrap_signing` so the regenerated profile carries the new capability.

### 4.2 xcodegen `project.yml` (no manual pbxproj surgery needed — key finding)

This repo generates the Xcode project in CI via xcodegen, so the extension target
is **declared in project.yml**, not hand-surgered into project.pbxproj:

```yaml
targets:
  JarvisWidgets:
    type: app-extension  # WidgetKit extension
    platform: iOS
    sources: [JarvisWidgets]
    dependencies:
      - target: JarvisApp   # embeds the extension in the app
        embed: true
        codeSign: true
    info:
      path: JarvisWidgets/Info.plist
      properties:
        CFBundleDisplayName: JARVIS Widgets
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.enriquecodes.jarvis.widgets
        CODE_SIGN_ENTITLEMENTS: JarvisWidgets/JarvisWidgets.entitlements
        # Widget extensions MUST have their own App Group entitlement
```

`JarvisWidgets/JarvisWidgets.entitlements`:
```xml
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.enriquecodes.jarvis.shared</string></array>
</dict>
```

### 4.3 Fastfile changes (only needed at extension time, not now)

- `match` call gains the app-extension profile (`app_identifier:
  ["com.enriquecodes.jarvis", "com.enriquecodes.jarvis.widgets"]`).
- `update_code_signing_settings` / ExportOptions.plist gain the extension's
  manual profile mapping.
- `upload_to_testflight` unchanged (extension rides the app archive).

### 4.4 Minimal widget code (when the time comes)

- `JarvisWidgetBundle.swift` — `@main WidgetBundle` with the widget list.
- `KrendoraAccountsWidget.swift` — `AppIntentTimelineProvider` +
  `WidgetConfigurationIntent` with `@Parameter(title: "Status filter")` etc.
- `SharedSnapshot.swift` (compiled into BOTH targets) — reads/writes
  `UserDefaults(suiteName: "group.com.enriquecodes.jarvis.shared")`.

### 4.5 Data flow (design)

```
JARVIS server (bridge /voice-gw / IG tooling)
        │  (app fetch, or Path B push later)
        ▼
JarvisApp  ──writes JSON snapshot──▶  App Group container
                                          │
                                 JarvisWidgets extension
                                          │
                              getTimeline → Timeline(entries:policy:.after(…))
                                          │
                                 Home screen / Lock screen widget
```

## 5. Risk register

| Risk | Mitigation |
|---|---|
| Second signing profile on CI | Match handles N app IDs; just list both. |
| Extension target breaks main app build | Extension is a separate target — a compile failure there fails CI, not the app target; the app archive still references the extension so CI fails loudly (good — no silent shipping of broken extensions). |
| Refresh budget exhaustion (widget "freezes") | Use `.after(nextCheckpoint)` timelines; batch entries; migrate to push reload after APNs key lands. |
| App Group name collisions | Single group per app; documented name here. |

## 6. Decision record — why the extension target is deferred

1. **Risk asymmetry:** adding a second, extension-signing phase to the Fastfile
   (match profiles × 2, update_code_signing_settings × 2, ExportOptions.plist × 2)
   risks regressing the shipping app build for zero user-visible value today.
2. **No user value yet** — Enrique explicitly said "on demand later."
3. **The hard, slow part is capability + data path** — the group name, signing
   recipe and data-flow design are locked now; the extension is a follow-up.
4. When the ask lands, §4 is a **paste-ready recipe** (xcodegen handles the
   pbxproj generation that manual surgery would have made risky).
