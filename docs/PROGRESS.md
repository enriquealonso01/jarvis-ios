## 2026-09-19 ~21:50 UTC (build-loop run) — 1j: POST /schedule/cancel was the bridge's one IRREVERSIBLE write with ZERO friction — an empty body `{}` (or a pydantic-shaped probe) wiped EVERY pending scheduled call silently (the scheduler has no undo, and a `cancelled: 0` reply even hinted success-by-proxy); cancel-all now requires `{"confirm": true}`, whitespace-only/unmatchable ids 404 loudly (was silent `cancelled: 0`), a non-string call_id 400s before pydantic v2 would raise an opaque 500; mirrored in call_enrique.py (`cancel --yes`) + the app's 404 path, pinned offline + live (selftest 27/27), deployed and prod-verified

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (the Swift 404-path change below rides
  the NEXT tag; bridge-side shipped to prod THIS run).
- The audit that found it: the 1f -> 1g ladder closed the input seams on
  /schedule (at_iso), /register (device_token), /call + /schedule (reason
  text) — this run audited the remaining write surface and found the only
  DESTRUCTIVE one had no guard at all: POST /schedule/cancel with an empty
  body cleared the ENTIRE schedule. Failure shapes: a buggy agent probe / a
  test body / a confused voice-tool call with `{}` erased every pending
  reminder permanently; `{"call_id": "   "}` (whitespace-only, e.g. from an
  untrimmed CLI arg) took the truthy branch, matched nothing, returned
  `cancelled: 0` — a silent no-op that LOOKED like an id-targeted cancel
  while implying the schedule survived (it did — but only by luck of the
  match); and an unknown id returned `cancelled: 0`, the same ambiguity the
  app already had to special-case as "maybe already fired".
- Fixed bridge-side (server/push_bridge/main.py): cancel-all now 400s
  "cancel-all requires {"confirm": true} — it wipes EVERY pending call and
  cannot be undone; to cancel one call send {"call_id": "<id>"}" unless
  confirm is EXACTLY true; a non-string call_id 400s "call_id must be a
  string" BEFORE model construction (pydantic v2 does not coerce — v1-style
  `0 -> ""` coercion would have been a wipe-shaped hazard, but v2 instead
  raises a raw ValidationError that uvicorn surfaces as an opaque 500; the
  guard turns both into a pinned 400); a whitespace-only call_id 404s with
  the exact remedy; an unmatchable id 404s "no scheduled call with call_id
  ... (nothing was cancelled)" — the cancelled-count lie is gone. Cancel-ONE
  stays confirm-free: it targets exactly one visible id.
- Client mirrors: scripts/call_enrique.py cancel-ALL now requires --yes
  (sends {"confirm": true}); a bare `cancel` or whitespace-only --id exits 1
  at composition time with the remedy — an agent cannot nuke the schedule
  with a reflex. iOS CancelView (CallsView.swift cancel()): the bridge's new
  404 for an already-gone id is caught (CCClient.Failure "HTTP 404") and
  mapped to the SAME friendly path as the old cancelled:0 race — refresh the
  list, "Already cancelled (or already fired)". Verified live through a real
  throwaway bridge on the wire (9/9: schedule two -> cancel-one 200 ->
  repeat 404 -> bare 400 -> nonstring 400 -> blank 404 -> confirmed-all 200
  -> list empty).
- Pinned in check_bridge_contract.py (1j): offline — CANCEL_GUARDS needles
  (both 400 details, both 404 details, the `body.get("confirm") is not True`
  gate itself); live — /schedule/cancel#unconfirmed-all (400) / #nonstring
  (400) / #blank-id (404) probed BEFORE the valid cancel, verdicted by
  cancel_guard_problems (a 200 to any probe fails the whole live layer),
  plus a #confirmed-all valid-shape probe so the gate cannot have bricked
  the documented cancel-all path. Selftest extended to 27/27 (T10a pinned
  details, T10b 200-regression caught, T10c wrong/no-detail caught, T10d
  offline gate-vanish caught). probe_call_bearer_live.py mirrors the guard
  on both AUTH paths + the not-bricked check — 26/26.
- Needle-authoring lesson (2nd of its kind, after 1g-bis's comment-masking):
  a needle containing `{"confirm": true}` must match the ESCAPED source form
  `{\"confirm\": true}` inside the Python string literal — the plain form is
  never in the file. Quote-free sub-strings ("it wipes EVERY pending call")
  are immune; used for both detail needles. Selftest caught the drift
  immediately (clean-tree check FAIL).
- Deployed via the documented sequence: py_compile OK -> LKG byte-synced ->
  systemctl restart -> /health ok:true (push_ok:0, scheduled:0 untouched).
  Prod live-verified with direct HMAC-signed probes: bare cancel-all 400
  (pinned detail), non-string 400, blank 404, unknown-id 404, confirmed-all
  200 {"cancelled": 0}, schedule still [], health unpolluted.
  check_deploy_parity ALL GREEN. CLI verified against live prod (old-code
  bridge accepts {"confirm": true} too — deploy-order safe both ways).
- Docs: API.md /schedule/cancel entry rewritten (confirm gate, 404s, CLI
  mirror); ARCHITECTURE.md 1f ladder entry extended (1j).
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).

## 2026-09-19 ~21:00 UTC (build-loop run) — 1g-bis: the LAST unguarded bridge write surfaces closed — POST /call + POST /schedule accepted an UNBOUNDED `reason` (it rides INSIDE the APNs payload; Apple rejects any notification over 4096 bytes, so an oversized /schedule entry persisted fine, burned 10 fire-time retries, then silently dropped the call — 1f-bis's silent-never class via payload SIZE); both surfaces now 400 empty/oversized text BEFORE firing/persisting, pinned offline + live, deployed to prod and live-verified

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code tag this run; the Swift
  composer change below rides the NEXT tag).
- The audit that found it: 1f-bis (at_iso) and 1f-ter (device_token) closed
  their input seams; this run audited the SIBLING write surfaces for the
  same class. POST /call and POST /schedule took `reason: str` (default
  "JARVIS call") and `scheduled_by: str | None` with ZERO size validation.
  The reason is serialized INTO the push payload (`{"aps": {}, **payload}`);
  APNs hard-rejects any notification over 4096 bytes with HTTP 413. Two
  failure shapes: /call with a huge reason = push attempts burn at Apple
  (push_fail climbs, call never lands); WORSE, /schedule with a huge reason
  persists cleanly, then at fire time APNs 413s, the scheduler burns its
  capped 10 retries, and the call silently drops — the exact
  persisted-then-never-delivered class 1f-bis killed for timestamps, via
  the payload-SIZE seam instead.
- Fixed bridge-side (server/push_bridge/main.py): shared
  `_validate_push_text(reason, scheduled_by)` — 400 "reason must not be
  empty — it is what the call screen shows"; 400 "reason too long (N bytes
  UTF-8 > 3500 limit) — APNs rejects any notification payload over 4096
  bytes, so this would burn 10 scheduler retries then silently drop the
  call"; 400 "scheduled_by too long (N > 200 chars)". 3500 bytes leaves
  >500 bytes of envelope headroom under Apple's 4096. Wired on BOTH /call
  and /schedule, BEFORE anything fires or persists.
- Client mirror (scripts/call_enrique.py): `call --reason` and
  `schedule --reason` now fail at composition time (exit 1, zero network
  calls) on empty/oversized text — the agent learns the moment it composes
  the command, same convention as the 1f-bis at_iso mirror. iOS-side:
  ScheduleCallSheet shows a live "Too long: N/3500 bytes" warning and
  disables Schedule (reason.utf8.count > 3500).
- Pinned in check_bridge_contract.py (1g-bis): offline — REASON_GUARDS
  needles (the shared-guard def + all three 400 detail literals) plus a
  BOTH-surfaces wiring count (`req.reason = _validate_push_text(...)`
  must appear exactly twice); live — the throwaway instance is probed with
  real empty/huge bodies (/call#empty /call#huge /schedule#huge) and must
  answer 400 with the pinned details (`reason_guard_problems`; a 200 to any
  probe fails the whole live layer). probe_call_bearer_live.py mirrors the
  guard on both AUTH paths + a not-overzealous check (normal reason still
  200) — 22/22. Selftest extended to 23/23 (T8c unwire caught, T8d
  needle-vanish caught, T9a/T9b/T9c verdict bite).
- COLLATERAL FIX the selftest caught: check_push_payload_contract.py's
  `aps`-envelope needle was the bare literal `{"aps": {}, **payload}` —
  my new guard COMMENT in _send_voip quotes that exact idiom, so T4's
  tamper (real send replaced by `json=dict(payload)`) read GREEN off the
  comment text. Needles now anchor the closing `)` of the real c.post
  statement; 1h selftest 10/10 again, lesson pinned in ARCHITECTURE.md.
- Deployed via the documented sequence: py_compile OK -> LKG byte-synced ->
  systemctl restart -> /health ok:true (push_ok:0 untouched). Prod
  live-verified with direct HMAC-signed probes: empty 400 + huge 400 on
  /call, huge 400 on /schedule with the pinned details; normal reason
  still 200; health unpolluted, schedule still [] (invalid bodies persist
  nothing). check_deploy_parity ALL GREEN.
- Docs: API.md /call + /schedule entries document the validation;
  ARCHITECTURE.md 1f ladder entry extended (1g-bis) + 1h A2-anchoring note.
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).

## 2026-09-19 ~20:20 UTC (build-loop run) — 1f-ter: the /register input hole CLOSED — the bridge persisted ANY device_token ≥20 chars unvalidated (a prose "token" overwrote the real registration silently: device_registered stays true, every future /call + /schedule push fires at a dead token, push_fail climbs, no error anywhere); now format-guarded bridge-side (≥64 lowercase hex, PushKit's exact wire format), pinned offline + live in 1f + probe_call_bearer_live, deployed to prod and live-verified

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code change this run, so no
  new tag — zero user-facing delta). Bridge :9160 healthy, device_registered
  still false (phone-side NEEDS-ENRIQUE unchanged).
- The audit that found it: 1f-bis closed /schedule's input seam; this run
  audited its SIBLING write surface, POST /register, and found the same
  class of hole one guard weaker: the only validation was
  `len(device_token) >= 20` — no format check at all. DEVICE_TOKEN is the
  bridge's ONLY push address: one malformed write (a buggy agent probe, a
  test body, a corrupted retry) silently bricks every future push while
  /health keeps saying device_registered:true. The 1f-bis failure classes
  (silent-never / instant-fire) map here to silent-forever-unreachable.
- Fixed bridge-side (server/push_bridge/main.py): /register now strips the
  token, requires >=64 chars (400 "device_token too short — PushKit tokens
  are 64 hex chars (32 bytes); refusing to overwrite a working
  registration"), and requires every char in 0-9a-f (400 "device_token
  must be lowercase hex (0-9a-f); refusing to overwrite a working
  registration") — BEFORE anything is persisted. The app sends exactly the
  pinned format (CallManager converts raw PushKit bytes with
  String(format: "%02x")); the real 32-byte token is 64 hex chars.
  Contract-additive: previously-valid registrations all still pass.
- Pinned in check_bridge_contract.py (1f-ter): offline — REGISTER_GUARDS
  needles (strip-normalize + both 400 detail literals) must exist in the
  deployed bridge source; live — the throwaway instance is probed with
  short ("short-token") and 64-char non-hex ("Z"*64) bodies on the way IN,
  BEFORE the valid-register probe, so a guard regression can never
  overwrite the probe token first (register_guard_problems verdicts; a 200
  to either probe fails the whole live layer). Selftest extended to 18/18
  (T7d pinned-details accepted, T7e 200-regression caught, T7f
  wrong/no-detail caught, T8b offline guard-vanish caught).
- probe_call_bearer_live.py mirrors the guard on both AUTH paths (Bearer
  short 400, HMAC non-hex 400) — 18/18.
- Deployed via the documented sequence: py_compile OK -> LKG byte-synced ->
  systemctl restart -> /health ok:true (push_ok:0 untouched). Prod
  live-verified with direct HMAC-signed probes: short 400 + non-hex 400
  with the pinned details, health unpolluted (device_registered still
  false — no probe side effects). check_deploy_parity ALL GREEN.
- Docs: API.md /register entry documents the validation; ARCHITECTURE.md
  1f ladder entry extended.
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).

## 2026-09-19 ~19:55 UTC (build-loop run) — 1f-bis: the /schedule input hole CLOSED — the bridge persisted ANY at_iso unvalidated (a garbage timestamp sat silent-never forever; a past timestamp RANG ENRIQUE INSTANTLY on the next 20s scheduler tick); now 400-guarded bridge-side, mirrored in the agent tool, pinned offline + live in 1f, deployed to prod and live-verified

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code change this run, so no
  new tag — zero user-facing delta). Tree clean, 0/0 vs origin.
- The audit that found it: post-backlog runs need fresh increments, so this
  run audited uncovered write surfaces. POST /schedule (bridge main.py) took
  `{at_iso, reason}` and persisted it with ZERO validation while the
  scheduler (`_run_scheduler_tick`) fires any persisted entry whose
  at_iso <= now on its next tick. Two failure classes rode on that seam:
  (1) an agent tool computing `--at` wrong (e.g. "10am" past, or a garbage
  string) either scheduled a call that never fires — dropped as "malformed"
  at fire time with no error anywhere — or (2) worse, rang the phone
  INSTANTLY. The one surface that fires real calls to Enrique had no input
  guard at all.
- Fixed bridge-side (server/push_bridge/main.py): /schedule now parses
  at_iso with `datetime.fromisoformat` (400 "at_iso is not a valid
  ISO-8601 timestamp" on garbage), normalizes naive -> UTC, and 400s
  "at_iso is in the past (UTC) — refusing to schedule an instant call"
  when due <= now — BEFORE anything is persisted. Naive timestamps stay
  accepted (same UTC assumption as the scheduler) so the change is
  contract-additive, not contract-breaking.
- Mirrored client-side (scripts/call_enrique.py): `schedule --at` fails at
  composition time (exit 1, zero network calls) on garbage/past
  timestamps; naive --at warns but proceeds. The agent learns the moment
  it composes the command, not after a persisted lie.
- Pinned in check_bridge_contract.py (1f-bis): offline — three needles
  (parse-reject + both 400 detail literals) must exist in the deployed
  bridge source; live — a throwaway instance is probed with real
  garbage/past bodies and must answer 400 with the pinned details
  (`at_iso_guard_problems` verdicts; a 200 to either probe fails the whole
  live layer — the instant-fire regression class can never read green).
  Selftest extended to 14/14 (T7a pinned-details accepted, T7b 200-regression
  caught, T7c wrong/no-detail caught, T8 offline guard-vanish caught).
  Two of the new tests bit their author first: the guard probes initially
  fell into the generic per-route decode loop (expect-200) and failed —
  they now skip it (dedicated verdict); the T8 tamper edit had to match
  the exact raise block.
- Deployed via the documented sequence: py_compile OK -> LKG byte-synced ->
  systemctl restart -> /health ok:true (push_ok:0 untouched). Prod
  live-verified with direct HMAC-signed probes: garbage 400 + past 400 +
  schedule list still empty. One probe byproduct (a naive-future schedule
  the client-mirror test created via the real prod bridge) was cancelled
  by id — schedule back to [], verified.
- Docs: API.md /schedule entry documents the validation; ARCHITECTURE.md
  1f ladder entry extended (offline + live guard pins, why).
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).

## 2026-09-19 ~17:45 UTC (build-loop run) — contract 8d: docs/BUILD.md was the LAST Enrique-facing surface still carrying stale instructions — "install build 1" (build 30 shipped Sep 19), "agents tell you when via WhatsApp DM" (403 since Sep 18), and the watch described as announcing to "Enrique's personal Signal DM" (UNREGISTERED_FAILURE since Sep 19); de-staled all three and pinned BUILD.md in check_doc_contracts.py, negative-tested (reverted copy -> 5 named FAILs, exit 1)

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code change this run, no new
  tag — zero user-facing delta). Bridge :9160 healthy, apns_configured:true,
  device_registered:false, APNs probe still 403 InvalidProviderToken on both
  legs (phone/key-side blockers unchanged, NEEDS ENRIQUE below).
- The gap this run closed: 8b/8c de-staled the one-shot mirrors and the watch
  script, but docs/BUILD.md — the doc Enrique actually opens on his Mac for
  the phone-side steps, the one ARCHITECTURE.md's "gated ladder" points him
  at — was in the scanner's blind spot (the checker read it only for the
  Push-Notifications/swap-script pointer pins, never for freshness). Its
  "Remaining:" section still instructed "install build 1, open it once";
  its update-cycle header routed notices "via WhatsApp DM"; its watch
  description claimed announcements go to his personal Signal DM. After
  tonight's 23:00 sunset, BUILD.md outlives every announcer — the last
  thing he'd read would have been a superseded build number and two dead
  channels. Exactly the class 8b/8c were written to kill.
- Fixed (3 spots in BUILD.md): install step is now build-number agnostic
  ("HIGHEST build number TestFlight shows", with the historical note: build
  1 shipped Sep 18, 30 is latest as of Sep 19, ITMS-rejected 19/20/21 never
  appear in TestFlight); update-cycle header now names the TF Ops Signal
  group as the ONLY delivery channel (WhatsApp 403, personal DM bouncing);
  watch description matches its real wiring (announcements AND failure
  notices -> TF Ops group). All three claims verified against live surfaces
  before editing (watch script + wiring checker + cron mirrors).
- Pinned as contract 8d in scripts/check_doc_contracts.py: BUILD.md scoped
  stale-claim list ("install build 1", "via WhatsApp DM", "announcements →
  Enrique's personal Signal DM"), positive pins for the "HIGHEST build
  number" instruction and TF-Ops-group delivery. The shared stale_claims
  list gained "install build 1" so every scanned surface (mirrors, watch,
  BUILD.md) bans it. Authored one false-positive trap and caught it before
  it shipped: my first claim list included the GOOD phrase "install JARVIS —
  pick the HIGHEST build" as absent — the same self-bite 8b hit; removed.
  Negative test: tmp clone + `git checkout -- docs/BUILD.md` (restores the
  stale copy) -> exactly 5 named FAILs, exit 1; real tree 71 doc-contract
  PASSes, full verify_all ALL GREEN.
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).


## 2026-09-19 ~17:10 UTC (build-loop run) — the LAST remaining announcer de-staled: the device-watch's own WAIT/KEY-LIVE lines still told Enrique to "install TestFlight build 1" (superseded by build 30 since Sep 19); after tonight's 23:00 sunset the watch is the ONLY announcer left, so that stale line would have been the last instruction he ever read from this mission — fixed, pinned as contract 8c, negative-tested

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code change this run, no new
  tag — zero user-facing delta). Bridge :9160 healthy, apns_configured:true,
  device_registered:false (phone-side blockers unchanged). Backlog stays
  CLOSED (docs/BACKLOG.md); all watch/sentinel/cron surfaces audited live:
  build-loop armed, device-watch ticking 15m (last run ok), sentinel 30m,
  both one-shots enabled with unchanged next_run 13:00/23:00 UTC — the
  13:00 guide already fired DELIVERED to the Ops group.
- The gap: 15:00's contract 8b de-staled the one-shot MIRRORS but missed
  scripts/testflight_device_watch.sh itself — its KEY-LIVE line said
  "Remaining: open TestFlight build 1 once on the phone" and its device-WAIT
  said "install TestFlight build 1 and open it once". Same failure class 8b
  was written to kill, in the script that OUTLIVES the one-shots.
- Fixed the three lines to build-agnostic "HIGHEST build" phrasing; synced
  the cron's EXECUTED copy at ~/.hermes/scripts/testflight_device_watch.sh
  (diff-proven identical — the cron runs the hermes copy, not the repo's;
  a repo-only fix would have shipped nothing).
- Pinned: doc contract 8c in scripts/check_doc_contracts.py — the watch
  script must carry no stale build-1 claim, MUST use "HIGHEST build"
  phrasing, and never mention WhatsApp (the watch's failure text is the
  future recovery instruction). Broadened the shared stale_claims list with
  the literal "TestFlight build 1" — and the negative test BIT ITS AUTHOR
  first: with the original 4-claim list, a tampered watch copy saying
  "install TestFlight build 1" PASSED (claim not listed; a second
  "HIGHEST build" phrase masked the positive check). After the broadening,
  the tampered copy FAILS with exactly one named line; the real tree passes
  clean (full verify_all ALL GREEN, 174 PASS lines).
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).


## 2026-09-19 ~16:20 UTC (build-loop run) — 1e-bis shipped: the CC-API checker's element-struct blind spot is CLOSED — collection element structs (Overview.Bridge/Project, ZaiUsage.Window, Automations.Item, Activity.Session, Attention.Alert, ChatsView's Board.Thread/Item) now pinned OFFLINE in both directions; selftest 7/7; verify_all ALL GREEN

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code change this run, no new
  tag — zero user-facing delta). Bridge :9160 healthy, apns_configured:true,
  device_registered:false (phone-side blockers unchanged).
- The gap this run closed: 1f (bridge) pinned collection element structs in
  BOTH directions when it landed, but 1e (dashboard surface) pinned only each
  model's TOP-LEVEL fields offline; the nested structs every Home/Chats list
  actually renders were checked only on the LIVE payload side. A Swift-side
  rename of e.g. Automations.Item.name left both layers green while the app
  decoded blank rows forever — the exact hazard class the checker ladder
  exists to kill, on the most-used surface in the app.
- New in scripts/check_cc_contract.py: ELEMENT_STRUCTS pins (8 element
  structs, req/opt split per the REAL Swift declarations — Overview.Bridge is
  all-opt because the app declares it Bool?/Bool?/Double?), a brace-aware
  extract_struct_body() (Board.Thread/Item live NESTED inside Board inside
  load(); naive regex-to-next-blank-line truncates them), and BOTH-direction
  validation: req-pinned must be declared non-optional, opt-pinned must be
  declared `T?` (the under-pin direction leaves decode-breaking fields
  unprotected — 1f's lesson). The strict pin bit its author before it bit
  the app, twice: my first pin declared Bridge.configured/reachable req
  (the Swift says Bool? — offline layer models the Swift, live layer models
  the payload), and T1's tamper anchor carried the wrong indentation.
- --selftest 7/7 on tmp copies (real tree untouched): element req-field
  rename, req field declared Optional (Attention.Alert.severity), opt field
  loses its ?, element struct vanish, Board.Item opt-field vanish, top-level
  req pin still armed, clean tree -> zero problems. Wired into verify_all as
  a second line in step 1e (same convention as 1f/1g/1h); live layer re-proven
  7/7 against the real dashboard in the same sweep. ARCHITECTURE.md's 1e
  ladder entry updated.
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).


## 2026-09-19 ~15:40 UTC (build-loop run) — bridge DEPLOY-PARITY gate shipped: the "prod is stale" phantom class killed at the root; setup-era /opt decoy removed (prod proven live-current); verify_all 5b-bis now pins repo == LKG == running process

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code change this run, no new
  tag — zero user-facing delta). Bridge :9160 healthy, apns_configured:true,
  device_registered:false (phone-side blockers unchanged).
- Incident that shaped this run: `systemctl is-active` under the wrong unit
  name + `diff repo vs /opt/jarvis-ios-bridge/main.py` showed 89 drifted
  lines → looked like prod was running code three feature-commits behind
  (missing transport-guard, push counters, push_ok on /health — exactly what
  the device-watch endgame depends on). Root truth: the unit's
  WorkingDirectory IS the repo; the /opt file was a setup-era copy loaded by
  NOTHING. Proof the live process is current: /health exposes push_ok /
  push_fail — fields that exist only since commit 1c42850 (01:01 UTC), after
  the 00:48 restart (tree edited pre-restart, committed after; the 09:04
  repo mtime was a no-op touch — `git status` clean).
- Removed /opt/jarvis-ios-bridge/main.py after proving (a) nothing loads it
  (unit ExecStart runs from the repo dir; no script, cron, or doc references
  it) and (b) it is byte-identical to commit 40daafe (sha256
  f0105284...4c0429d04) — fully recoverable from git. Service untouched and
  re-verified healthy after removal. Also confirmed: repo ==
  /opt/jarvis-ios-bridge-lkg/main.py (the DOCUMENTED rollback copy, current).
- New `scripts/check_deploy_parity.py` (verify_all step 5b-bis) turns the
  prose deployment contract into pins: unit WorkingDirectory -> repo dir +
  ExecStart runs uvicorn main:app; repo py_compiles; LKG byte-identical to
  repo (a stale LKG = every future "safe rollback" is a lie); live /health
  answers ok:true WITH push_ok (capability marker — a stale running copy or
  stale .pyc shadow fails loudly); state files present.
  `--selftest` negative-tests 5 ways (stale LKG, wrong/missing
  WorkingDirectory, repo syntax error) on a fully synthesized tmp tree —
  5/5 PASS, real tree never touched; live audit 7/7 PASS.
- docs/ARCHITECTURE.md push-bridge section now records the three-copies
  contract + the no-ghost-copies rule with this incident as the why.
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).

## 2026-09-19 ~15:00 UTC (build-loop run) — BACKLOG FORMALLY CLOSED: all nine launch items audited against the codebase and verified done; docs/BACKLOG.md written as the durable 9/9 record with per-item evidence pointers — post-backlog mode begins (fresh increments + maintenance, not list-grinding)

- Run-start sweep: verify_all ALL GREEN including the ship gate — ios-v28 ->
  run #30 -> build 30 VALID + IN_BETA_TESTING (still the shipped latest; this
  run changes no app code, so no tag — zero user-facing delta).
- Per-item audit that justified closing (each checked in the tree, not from
  memory): (1) app shell = RootTabView Home/Chats/Secrets/Calls + HomeView
  cards; (2) Chats + CCClient proven live by contract checkers 1e/1g;
  (3) Secrets via bridge routes proven by 1f; (4) Calls = CallKit/PushKit/
  WebRTC proven by 1h payload contract + live aiortc e2e; (5) bridge
  /register + /schedule list/cancel in main.py, pinned in docs/API.md;
  (6) gateway native WebRTC on the orb's session.py pipeline, documented;
  (7) fastlane Fastfile + scripts/upload.sh (+--build-only); (8)
  scripts/call_enrique.py + voice tools call_enrique/schedule_call live
  under ~/.hermes/jarvis/voice_tools/; (9) icon+launch screen (ICON.md),
  load-failure-vs-empty states in Secrets/Calls, Haptics.swift, SettingsView.
- docs/BACKLOG.md now carries the table (item / status / evidence) + standing
  state: build 30 shipped, verify_all as the maintenance surface, the three
  NEEDS-ENRIQUE blockers, and the fail-closed ring-path endgame (device-watch
  fires a real verification call and only then declares MISSION COMPLETE).
- Future runs: read BACKLOG.md first, run verify_all, maintain + take fresh
  increments. No backlog item remains to "do next".

## 2026-09-19 14:05 UTC (build-loop run) — the 9AM setup guide NEVER reached Enrique: his personal Signal DM bounces UNREGISTERED_FAILURE (account unregistered server-side, live-proven with a minimal direct send); both one-shot announcers + the device-watch repointed to proven Signal groups, guide re-fired and DELIVERED (last_status=ok), sunset tonight now aims at a working channel

- Found by the run-start sweep, not by luck: verify_all 5d flagged
  `jarvis-ios-apple-setup-guide -> MISSING/DISABLED`. The old enabled-only
  check was RIGHT that something was wrong and WRONG about what: the 13:00
  one-shot had FIRED, composed the perfect guide, and its Signal delivery
  FAILED (`last_status=delivery_failed`, Signal RPC -1). A completed one-shot
  self-disables — the check then cried MISSING forever, and the real failure
  (content existed, Enrique never saw it) was invisible.
- Root cause chased through three re-fire attempts: (1st) `hermes cron run`
  on a completed one-shot is rejected → `resume --run-now`; that run died
  with the box's own restart (`Interrupted by shutdown` — same 13:33 flap
  that reset every daemon PID); (2nd) failed with the same RPC error as 13:00
  — not transient; (3rd) extracted the exact wire truth from
  `last_delivery_error`: `UNREGISTERED_FAILURE` for his DM number. Verified
  OUT OF BAND with a one-line direct signal-cli `send` RPC to the DM: same
  UNREGISTERED_FAILURE — while every group send (Ops ITfF, mission Gd7A,
  Krendora nY3C) delivers ok, including the device-watch's own DM SUCCESS at
  13:32, so the account died server-side between 13:32 and 13:45 (recovery:
  Enrique re-registers his Signal; nothing agent-side can fix it).
- Fixes shipped (commit 933fa1e, pushed, origin/main verified):
  - verify_all 5d made delivery-state-aware: one-shot + state=completed +
    last_status=ok -> `DELIVERED` (PASS); last_status!=ok -> FAIL loudly
    ("DELIVERY FAILED — re-fire it"); recurring jobs unchanged (exist +
    enabled). A fired one-shot can never again read as lost coverage, and a
    fired-but-failed one can never read as delivered.
  - check_watch_wiring contract 4 repointed: device-watch announcements ->
    TF Ops group (Gd7A), root cause + date pinned in the docstring;
    ALL PINS HOLD re-verified live.
  - Both one-shot prompts (mirrors + live crons, byte-identical) refreshed:
    deliver target -> Ops group (ITfF) with the WHY in-line (DM
    UNREGISTERED_FAILURE 13:48 UTC, WhatsApp 403 since 9/18 — deliver to
    NEITHER), and the stale build-29 claims bumped to build 30 (that text
    predated the ios-v28 ship). Doc contracts ALL PASS.
  - Guide re-fired on the fixed channel: `last_status=ok` — Enrique HAS his
    5-step setup guide (TestFlight → highest build = 30 → sign-in → new APNs
    key → Signal ring test). Tonight's 23:00 UTC sunset delivers its wrap-up
    to the same proven channel.
- Ship gate at run start: ios-v28 -> run #30 -> build 30 VALID +
  IN_BETA_TESTING — still the shipped latest; this run changed no app code,
  so no new tag was cut (a build with zero user-facing delta is waste).
- NEEDS ENRIQUE (now three, all phone/web-side): (1) APNs-capable .p8
  (scripts/swap_apns_key.py installs it in one command), (2) phone — open
  TestFlight, install the HIGHEST build (30), sign in once
  (device_registered must flip true), (3) NEW: re-register his personal
  Signal account (the DM bounces UNREGISTERED_FAILURE; groups work —
  watchdog convention "personal -> DM" is broken until he does).
- Next run: proceed down the backlog (call_enrique voice-tool wiring already
  live; remaining polish is app-side and rides the next tag); 5d now proves
  the announcer channel instead of assuming it.

## 2026-09-19 12:55 UTC (build-loop run) — SHIP GATE shipped: the poll-by-hand era ends; ios-v28 -> run #30 -> BUILD 30 VALID + IN_BETA_TESTING verified live and now provable in ONE command forever

- This run's first act: verify last cycle's promise actually landed. Run 30
  (tag ios-v28, created 12:02Z) completed success, ASC upload row
  cfBundleVersion=30 COMPLETE, build 30 processingState VALID,
  internalBuildState IN_BETA_TESTING, autoNotify enabled — so **build 30 is
  the latest TestFlight build** and it CARRIES THE TEXT-PING KEEPALIVE FIX
  (merge-base-verified: ios-v28 contains e77b26f). Build 29 still installed
  on the phone = binary ping; opening 30 flips it. The 12:05 run's "fix rides
  the next tag build" is now TRUE and PROVEN, not assumed.
- Built what this manual verification kept repeating: `scripts/ship_gate.py`
  — one command walks the real chain fail-closed: (hop1) latest local ios-v*
  tag exists on origin — the 12:05 failure class (committed, unpushed, no
  tag); (hop2) that tag's ios-release Actions run concluded success — auth
  from git's own credential store (never printed; anonymous API is 404);
  (hop3a) ASC shows build <run-number> VALID with 3x20s ingest-lag retry;
  (hop3b) internalBuildState IN_BETA_TESTING. Any hop missing/red/lagging
  FAILS loudly — a run that can't prove "shipped" says so instead of
  assuming. Live-proven green end-to-end this run.
- Negative-tested the house way (`scripts/selftest_ship_gate.sh`, throwaway
  clones, real tree untouched): T1 local-only tag bites with the exact
  12:05-class message; T3 uses REAL historical failure data — ios-v26 = run
  28 concluded failure — proving a RED run can't read as shipped; T4 missing
  git credentials fails as a clean one-line config error. T4 found a real
  gate bug on first authoring (missing credentials file -> raw traceback);
  fixed, and the selftest's own T3 first draft PASSED a red gate (ios-v27 is
  legitimately shipped — wrong premise) which is exactly why negative tests
  need real failure data, not invented tags.
- Selftest infra lesson pinned in its header: a throwaway HOME needs BOTH
  .gitconfig (credential.helper pointer) AND .git-credentials (the token);
  copying only the store file silently de-auths git. T2 (origin lists the
  ref but lacks its commit) is impossible for refs — ls-remote only lists
  what it can serve — noted in the script.
- Wired into verify_all.sh as step 8/6 (gate + selftest): step 7 proves
  nothing unpushed, step 8 proves the pushed thing SHIPPED. Full sweep ALL
  GREEN with both aboard (doc contracts, swift sanity, drop/scheduler, APNs
  probe warn, push counters, 1d–1h checkers, bearer probes, live health,
  parity, watch+sentinel 18/18, native WebRTC e2e, ship gate).
- Live state: build 30 VALID + IN_BETA_TESTING (latest), build 29 also
  VALID, device_registered:false, push_ok:0, probe verdict 403
  InvalidProviderToken — both blockers still Enrique-side, unchanged.
- NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  installs it), (2) phone — TestFlight → open the HIGHEST build (30 now) →
  sign in once; device-watch announces each flip within 15 min.
- Next run: proceed down the backlog (launch-screen/icon polish or
  call_enrique voice-tool wiring per docs/API.md); ship gate now makes
  "did the last tag ship?" a zero-effort check at run start.
## 2026-09-19 12:05 UTC (build-loop run) — the isBinary keepalive fix was SITTING UNPUSHED: local main was 2 commits ahead of origin and no tag existed past ios-v27, so "fix rides the next tag build" had no vehicle — pushed main, cut ios-v28 → CI now builds build 30 carrying the TEXT-ping fix

- Found by this run's first-ever local-vs-origin audit: `git log
  origin/main..HEAD` = 2 commits (e77b26f the keepalive fix + ab62426 the
  11:27 docs entry). The 11:27 run committed the fix locally but NEVER
  pushed, and the latest tag was ios-v27 (build 29) — so the promise
  "fix rides the next tag build" was structurally unreachable from this
  box: nothing on GitHub carried the fix, and every future tag would be
  cut from whatever HEAD happened to be local. Build 29 on TestFlight
  still ships the binary ping. Lesson pinned here: every run begins with
  `git fetch` + ahead/behind check BEFORE choosing work.
- Sequence this run: verify_all ALL GREEN first (never push unverified),
  then `git push origin HEAD:main` (95b888b..ab62426, verified via
  ls-remote: origin/main == ab62426), then tag `ios-v28` + push → fires
  ios-release.yml (tag pattern ios-v*; build number = GitHub run number →
  this is BUILD 30) with the TEXT keepalive fix aboard.
- Guard added so this class is structurally dead: verify_all step 7 now
  does `git fetch` + rev-list against origin/main and FAILS the sweep if
  any local commit is unpushed (negative-tested in a throwaway clone: a
  tmp commit → "FAIL: 1 commit(s) ... NOT pushed" naming it; real tree →
  PASS, full sweep ALL GREEN). A run can no longer end with unpushed
  work surviving silently.
- Next run MUST: read the Actions run status for tag ios-v28 (run list via
  authenticated API — anonymous /actions/runs is 404) and poll ASC for
  build 30 (upload row cfBundleVersion=30 COMPLETE → BUILD: 30 VALID +
  IN_BETA_TESTING); on green, repoint NEEDS-ENRIQUE at build 30. Cycle is
  ~90 min end-to-end per the ios-v27 precedent.
- Live state unchanged: build 29 VALID + IN_BETA_TESTING (count 2),
  device_registered:false, push_ok:0, probe verdict 403
  InvalidProviderToken — both blockers still Enrique-side.
- NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  installs it), (2) phone — TestFlight → open the HIGHEST build (29 now,
  30 once this tag lands green) → sign in once; device-watch announces
  each flip within 15 min.

## 2026-09-19 11:27 UTC (build-loop run) — REAL BUG on the native call path: the app's data-channel keepalive shipped as a BINARY ping (isBinary:true) — pipecat only counts TEXT pings, so every iOS call since build 1 has run with a dead keepalive + per-second json.loads error spam on the gateway; fixed + pinned

- Audit this run walked the app↔gateway WebRTC contract against pipecat's
  actual source (not the docs) and found the seam: WebRTCClient's 1 Hz
  liveness ping was `Data("ping".utf8), isBinary: true`. The gateway side
  (SmallWebRTCConnection, connection.py:352) counts a keepalive ONLY for
  `isinstance(message, str)` frames that start with "ping"; a binary frame
  falls through to `json.loads(b"ping")`, raises, is error-logged EVERY
  SECOND of every call, and `_last_received_time` never advances — so
  `connection.is_connected()` (3s liveness window) reads DEAD for iOS
  sessions regardless of reality, while the web orb (JS `dcSend('ping')` →
  string) and probe_webrtc_native.py (aiortc `channel.send("ping")` → str)
  both pass. Proven at the wire level too: aiortc marks str frames with
  PPID WEBRTC_STRING(51) and bytes with WEBRTC_BINARY(53) — the types
  genuinely differ on the wire; this was never a cosmetic distinction.
- FIX (ios/JarvisApp/WebRTCClient.swift): `isBinary: false` + a comment
  naming the contract so the next reader doesn't "clean it up" back to
  binary. No gateway change needed (gateway behavior is correct; the app
  was the sole deviator). Rides the next tag build (ios-v*); build 29 on
  TestFlight still carries the binary ping — harmless to call audio, but
  the keepalive + log-spam fix only lands with the next upload.
- PINNED so it cannot regrow: swift_sanity required pin on the exact text
  send (`Data("ping".utf8), isBinary: false`), negative-tested on a tmp copy
  (reverting to isBinary:true removes the needle → sanity FAIL, restore →
  PASS). ARCHITECTURE.md + GATEWAY.md now say TEXT is load-bearing with the
  root cause; aiortc PPID evidence recorded here.
- Full verify_all sweep ALL GREEN with the fix aboard (doc contracts,
  sanity, drop/scheduler, APNs probe warn, push counters, 1d–1h checkers,
  bearer probes, live health, parity, watch+sentinel 18/18, native WebRTC
  e2e vs the live gateway — which itself proves the TEXT ping keeps a
  session alive end-to-end).
- Live state unchanged: build 29 VALID + IN_BETA_TESTING,
  device_registered:false, push_ok:0, probe verdict 403
  InvalidProviderToken — both blockers still Enrique-side.
- NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  installs it), (2) phone — TestFlight → open BUILD 29 → sign in once;
  device-watch announces each flip within 15 min.

- Layer A (offline pins, 9 of them): (1) SET-equality between the payload
  keys every bridge fire site builds — /call handler and the scheduler-tick
  construction site, each pinned to exactly
  `{reason, call_id, gateway_ws, scheduled_by}` — and the keys the app
  reads; the pin is the LITERAL set, so even a coordinated both-sides rename
  fails until the contract is consciously re-pinned (a silent both-sides
  drop is exactly the class the fallback reads mask). (2) the top-level
  `aps` envelope (`{"aps": {}, **payload}` — Swift reads SIBLINGS of aps).
  (3) the literal `"/voice-gw"` value (the app dials
  `base + gatewayWS + "/api/offer"`). (4) every required key is read with
  the `?? fallback` shape (the hazard set made explicit). (5) the Swift
  `VoIPPayload` struct req/opt split (gatewayWS must stay non-optional —
  T7 negative-tests declaring it `String?`). (6) single-reader placement:
  every `payload[...]` read in CallManager must sit INSIDE
  `handleVoIPPayload` (occurrence-position check; a rogue second reader
  = drift). (7) the post-end redelivery guard dedupes on `p.callID`.
  (8) gateway still serves the `/voice-gw` offer path.
- Layer B (live send-path, no network): imports the REAL bridge module into
  the checker process pointed at a tmp state dir (BRIDGE_NO_SCHEDULER off
  for the tick path), stubs httpx.Client + jwt to CAPTURE the serialized
  JSON body instead of POSTing, then drives (1) the direct /call payload
  through the real `_send_voip`, (2) a REAL due scheduler tick
  (`_run_scheduler_tick` with a due entry in scheduled_calls.json — the
  tick's own construction site, not a copy of it), and (3) both early-exit
  paths (unconfigured, no-device) which must capture NOTHING (round-trip-
  only semantics). Each captured body decodes against an exact shadow of
  the app's read: `aps` top-level, required keys present + non-empty
  String, `scheduled_by` nullable-optional, `gateway_ws == "/voice-gw"`.
- Selftest 10/10 (tmp copies, real tree untouched): bridge one-sided key
  rename, app-side read rename, COORDINATED rename (caught — pin is the
  literal set), aps-envelope vanish, live optional-drop tolerated
  (scheduled_by absent is legal), live null-of-required caught, Swift
  struct req→opt drift caught, rogue second reader caught, clean tree
  passes. The selftest caught THREE real checker bugs before first commit
  (reader-block regex ended before the reads; A5 compared Swift names to
  wire keys; the position-span check needed occurrence positions, not key
  names) — the strict selftest bites its author first, again.
- Wired into verify_all.sh as step 1h (checker + selftest, same convention
  as 1f/1g); ARCHITECTURE.md ladder section extended to 1d–1h. Full sweep
  ALL GREEN with 1h aboard (doc contracts, swift sanity, drop/scheduler,
  APNs probe warn, push counters, 1d–1g, bearer probes, live health,
  parity, watch+sentinel 18/18, native WebRTC e2e).
- Live state unchanged: build 29 VALID + IN_BETA_TESTING,
  device_registered:false, push_ok:0, probe verdict 403
  InvalidProviderToken — both blockers still Enrique-side.
- NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  installs it), (2) phone — TestFlight → open BUILD 29 → sign in once;
  device-watch announces each flip within 15 min.

## 2026-09-19 10:00 UTC (build-loop run) — the app's WRITE path pinned: new step 1g chat send-path contract checker proves the Chats tab's actual SEND surface (POST /work/{id}/chat, POST /project/task, GET /work/{id}/history) — routes, Swift models, and the pre-LLM 400 guards proven LIVE with ZERO model calls (selftest 10/10, full sweep ALL GREEN)

- Backlog 1–9 re-verified DONE against the tree; live state unchanged (build
  29 VALID + IN_BETA_TESTING, device_registered:false, push_ok:0, probe
  verdict 403 InvalidProviderToken — both blockers still Enrique-side).
  Next-highest value: 1e (08:19) pinned the seven Home/Chats READS and 1f
  (09:15) the bridge Secrets/Calls surface, but the app's only WRITE path to
  the dashboard — ChatsView.startTask → POST /api/control/project/task,
  ChatView.send → POST /api/control/work/{id}/chat, and both threads'
  GET /api/control/work/{id}/history poller — had no contract proof at all.
  A dashboard rename would have surfaced as a silently dead chat; worse, a
  refactor moving the empty-text guard BEHIND _run_jarvis_turn would have
  turned every accidental empty send into a full LLM spin (the button's
  sending state hangs) with nothing failing anywhere.
- NEW scripts/check_chat_contract.py, wired into verify_all.sh as step 1g.
  Layer A (offline): all 3 routes must exist in the deployed dashboard
  source, the two pre-LLM 400 guards (detail="empty message" /
  detail="empty task") must still sit in the handlers, and the Swift models
  (WorkChatReply.reply req, WorkHistory available req + session_id/messages/
  total opt, ChatsView's TaskReply.reply req) must declare the exact req/opt
  split. Layer B (live): mints a dashboard bearer like 1e and proves —
  (1) POST work chat with whitespace-only text → 400 {"detail": …}, which is
  only possible because the guard precedes the agent turn, so the probe is
  FREE (zero tokens, zero session writes); (2) POST project/task empty-text
  → 400 same guarantee; (3) GET history for a nonexistent id → 200 decoding
  into the app's WorkHistory shadow (the empty shape: available:false,
  messages:[]); (4) NON-VACUOUS element shadow — takes the busiest real
  session from /api/control/activity (same source as the Chats board) and
  decodes its history (140 messages this run), checking each element's
  required `role`. Offline-only when the dashboard is down (SKIP convention);
  429 tolerated as alive.
- Negative-tested IN-REPO (--selftest, tmp copies — the real tree is never
  touched): route-vanish, struct-vanish, req-field-vanish,
  req→opt misclassification (available: Bool? must FAIL), guard-vanish,
  live decode-gap, element-role gap, real-shape-positive, 400-body gap,
  clean-tree no-false-positive — 10/10 PASS.
- verify_all ALL GREEN with 1g aboard: doc contracts, swift sanity, drop/
  scheduler checks, APNs probe (warn), push counters, login (1d), CC reads
  (1e), bridge (1f), chat send (1g), bearer probes, live health, parity,
  watch+sentinel 18/18, native WebRTC e2e. ARCHITECTURE.md now documents the
  full 1d–1g checker ladder ("Contract checkers" section).
- NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  installs it), (2) phone — TestFlight → open BUILD 29 → sign in once;
  device-watch announces each flip within 15 min.

- Backlog 1–9 re-verified DONE against the tree; live state unchanged (build
  29 VALID + IN_BETA_TESTING, device_registered:false, push_ok:0, probe
  verdict 403 InvalidProviderToken — both blockers still Enrique-side).
  Next-highest value: step 1e (08:19) pinned the DASHBOARD half (Home +
  Chats); the app's bridge-side surface — every Secrets and Calls tab call —
  decoded into six Swift models (`SecretsListResp`, `SecretWriteResp`,
  `ScheduledCall`, `SchedResp`, `CallResp`, `CancelResp`) with NO contract
  proof at all. A bridge rename or dropped field would have surfaced only as
  a silently blank Secrets list or stale schedule on the phone.
- NEW scripts/check_bridge_contract.py, wired into verify_all.sh as step 1f.
  Layer A (offline): all 8 routes must exist in server/push_bridge/main.py
  (/secrets, /secrets/set, /secrets/delete, /register, /schedule/list,
  /schedule, /schedule/cancel, /call), Swift structs must declare the pinned
  fields, COLLECTION ELEMENT structs are pinned offline too (SecretMeta,
  ScheduledCall — a blind spot 1e still has), and the req/opt SPLIT is
  verified BOTH directions (req-pinned must be non-Optional, opt-pinned must
  be `T?` — the under-pin direction leaves decode-breaking fields
  unprotected). /register pins route + request keys only (the app checks
  HTTP 200, no decode). Layer B (live): spawns the throwaway bridge exactly
  like probe_call_bearer_live.py (tmp state dir, scheduler off, always
  killed), drives every endpoint with a real dashboard Bearer in an order
  that leaves both collections NON-EMPTY when listed (set→list→delete,
  schedule→list→cancel) so element shadows are never vacuous, with a
  vacuous-element guard that FAILS if both list samples come back empty,
  and decodes against an EXACT shadow of Swift's synthesized Decodable:
  req = keyNotFound/typeMismatch-null, opt = presence-only (UI degrades).
  Contract throwaway names only; prod bridge untouched (tmpfs state, port
  9163, process killed at exit).
- First run caught a REAL bug — in the new checker itself: /secrets/set
  never returns `deleted` (delete-only key), so the strict pin failed its
  own live decode. Contract corrected per-endpoint; lesson recorded: the
  strict pin bites its author before it bites the app.
- Negative-tested IN-REPO (`--selftest`, tmp copies — the real tree is never
  touched, unlike 1d/1e's hand-run tamper rituals): route-vanish,
  struct-vanish, req-field-vanish, element-struct-vanish,
  element-field-rename, live element rename → keyNotFound, live key drop,
  live req-null → typeMismatch, req/opt misclassification, clean-tree
  no-false-positive — 10/10 PASS. verify_all ALL GREEN with 1f aboard: doc
  contracts, swift sanity, drop/scheduler checks, APNs probe (warn), push
  counters, login contract (1d), CC contract (1e), bridge contract + selftest
  (1f), bearer probes, live health, parity, watch+sentinel 18/18, WebRTC e2e.
- NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  installs it), (2) phone — TestFlight → open BUILD 29 → sign in once;
  device-watch announces each flip within 15 min.

## 2026-09-19 08:19 UTC (build-loop run) — the path AFTER sign-in now pinned: new step 1e CC-API contract checker proves every Home/Chats endpoint the app calls EXISTS on the live dashboard and DECODES into the app's exact Swift models (7/7 live 200 decode-OK)

- Backlog 1–8 re-verified DONE against the tree; live state unchanged (build
  29 VALID + IN_BETA_TESTING, device_registered:false, push_ok:0, probe
  verdict 403 InvalidProviderToken — both blockers still Enrique-side).
  Next-highest value: 06:45's run proved the sign-in path (step 1d); the
  FIRST thing the app does after sign-in — Home loading seven cards, Chats
  loading the dispatch board — had no contract proof at all. A dashboard
  rename or field removal would have surfaced only as a silently blank card
  on the phone.
- NEW scripts/check_cc_contract.py, wired into verify_all.sh as step 1e.
  Layer A (offline): all 7 routes must exist in the deployed dashboard
  source (/api/control/vitals, overview, zai_usage, automations, activity,
  attention, dispatch/board) and the Swift structs (Vitals, Overview,
  BridgeHealth, ZaiUsage, Automations, Activity, Attention, WorkChatReply,
  WorkHistory in CCClient.swift; Board in ChatsView.swift) must declare the
  pinned required fields. Layer B (live, read-only GETs): mints a dashboard
  bearer exactly like the other probes and fetches each endpoint, decoding
  against a shadow of the Swift model with the same optionality split
  (required = non-optional `let`, optional = `T?`); unreachable dashboard =
  SKIP-not-fail, 429 tolerated as alive (check_login_contract conventions).
- First-ever live proof of the Home payload contract: all 7 endpoints
  returned 200 and decoded clean — including /overview (first probe hung ~10s
  on PC-bridge lookup; healthy at 25s timeout, bridge.reachable:true) and
  /attention (currently carrying one real crit alert: krendora-fb-bulk-
  inquiries automation failing, exactly what the app's alert card would
  show). Notes: vitals is the one all-required model; the dispatch board's
  thread items' free-text fields left unpinned (no contract value).
- Negative-tested per repo convention: route-vanish, struct-vanish,
  field-vanish, and two live-decode-gap classes all caught (each tamper made
  the checker exit 1 with a named pin); full verify_all ALL GREEN with 1e
  aboard — doc contracts, swift sanity, APNs probe (warn), push-counter
  shadow, login contract, bridge bearer probe, gateway gate, live health,
  parity, watch+sentinel 18/18, native WebRTC e2e.
- NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  installs it), (2) phone — TestFlight → open BUILD 29 → sign in once;
  device-watch announces each flip within 15 min.


## 2026-09-19 07:50 UTC (build-loop run) — Enrique-facing one-shots DE-STaled: today's 9AM setup guide and 11PM sunset wrap-up no longer tell him to install build 1 or run the ring test over WhatsApp; freshness contract 8b now pins both mirrors

- Found by this run's live-state pass: both one-shot cron prompts still
  carried pre-build-29 text — "install JARVIS **build 1** (1.0 (1))",
  "build 1 is the first and only build that exists", "TestFlight status
  (build 1 LIVE...)", and a ring test routed "on WhatsApp" (403'd since
  Sep 18). The guide fires 13:00 UTC TODAY (9AM Miami): he would have been
  told to install a superseded build; the sunset (23:00 UTC) would have
  repeated it in the wrap-up. Build 29 is VALID + IN_BETA_TESTING since
  Sep 18 22:57 PT — the text predated it.
- Fixed BOTH sides, mirror-first per the byte-identity contract:
  scripts/cron_prompts/apple_setup_guide.txt + loop_sunset.txt now say
  install the HIGHEST build number TestFlight shows (build 29 the latest
  as of Sep 19, build 1 superseded, ITMS-rejected 19/20/21 never shipped),
  releases stay automatic on tag push, and the ring test runs on SIGNAL
  (WhatsApp 403 note kept). Live jobs 2203e22d518d / 3b3cf2b06cad updated
  via `hermes cron edit --prompt "$(cat mirror)"`; verified from the live
  store: byte-identical to mirrors, enabled:true, state:scheduled, next_run
  13:00 / 23:00 UTC unchanged. Completed one-shot jarvis-ios-resume-loop
  audited and left alone (done 2026-09-18, correctly disabled).
- Contract 8b added to scripts/check_doc_contracts.py so this staleness
  class can never silently regrow: mirrors must contain NO build-1-only
  claims ("the FIRST and ONLY build" et al.), MUST carry the state-driven
  "HIGHEST build number" instruction, and MUST NOT route the ring test to
  WhatsApp — future-proof past build 30+. verify_all ALL GREEN with 8b
  aboard (all pins incl. live-vs-mirror byte-identity).
- Live state unchanged: build 29 VALID + IN_BETA_TESTING, device_registered
  false, push_ok 0, probe verdict 403 InvalidProviderToken (ASC-only key),
  schedule clean. NEEDS ENRIQUE unchanged: (1) APNs-capable .p8
  (scripts/swap_apns_key.py installs it), (2) phone — TestFlight → install
  the HIGHEST build (29) → sign in once; device-watch announces each flip
  within 15 min. Today's guide now points him at exactly that.


## 2026-09-19 06:45 UTC (build-loop run) — the sign-in path PROVEN for the first time: a full audit of the day-one "open + sign in" journey found no blocking bug (the suspected PasswordLoginBody slip was a misread), and a live probe now pins the app↔dashboard PKCE contract — authorize 302+PKCE cookie, brokered password-login reaching the credential check, loopback-redirect boundary — as verify_all step 1d

- Backlog 1–8 re-verified DONE against the tree (app shell, Chats, Secrets,
  Calls/CallKit/PushKit/WebRTC, bridge /register + schedule endpoints +
  scheduler, gateway WebRTC + voice tool, call_enrique CLI, fastlane CI);
  #9 icon/launch/haptics/settings ship in project.yml + assets. The build
  number chain that produced build 29 came from xcodegen's GITHUB_RUN_NUMBER
  (CURRENT_PROJECT_VERSION: "20" in project.yml is stale, harmless — CI
  overrides it; zeroed to "0" this run to kill the confusion at the source).
- AUDIT (the one day-one path nothing had ever exercised: sign-in):
  walked AuthStore's whole RFC 8252 round trip against the deployed
  dashboard routes — authorize query (S256 + literal-loopback redirect,
  which the server REQUIRES; 'localhost' is rejected), password-login body
  model, next→?code= extraction, token/refresh bodies + decode. Found and
  disproved one suspect: a first read of AuthStore.swift:207 suggested
  `self.password = username` (every sign-in bricked); grep + regex on the
  REAL file proved the line is correct — a lesson in re-reading before
  writing. LIVE probes against jarvis.enriquecodes.com: /auth/native/
  authorize → 302 /login + __Host-hermes_session_pkce cookie (broker handoff
  alive); brokered /auth/password-login with a probe body → 401 "Invalid
  credentials" — i.e. provider=basic resolves, the PKCE cookie is ACCEPTED,
  the app's exact body shape parses, and flow control reaches the
  credential check (the only step needing real creds); non-loopback
  redirect → 400 (open-redirect boundary intact). Token/refresh endpoints
  return {access_token, refresh_token, expires_at} — exactly the app's
  decode. Verdict: nothing blocks flip 2 (Enrique's sign-in) server-side.
- PINNED so it cannot drift: scripts/check_login_contract.py (layer A: 22
  structural pins on AuthStore.swift incl. a NEGATIVE-tested
  password=username tamper check; layer B: the three live probes above,
  SKIPPED-not-failed when the dashboard is unreachable, 429 tolerated as
  alive) wired into verify_all.sh as step 1d. First sweep run caught its
  own bug — urllib silently followed the authorize 302 and read the login
  page's 200 as the status; NoRedirect handler added, contract re-proven.
- verify_all ALL GREEN with 1d aboard (doc contracts, swift sanity, APNs
  probe, push-counter shadow, bearer probes, live health, parity, watch +
  sentinel wiring + 18/18 behavior, WebRTC e2e 6/6).
- Live state unchanged: probe verdict still 403 InvalidProviderToken
  (ASC-only key), device_registered:false, push_ok:0, build 29 VALID +
  IN_BETA_TESTING (count 2), schedule clean. NEEDS ENRIQUE unchanged, now
  with sign-in PROVEN up to real credentials: (1) APNs-capable .p8
  (scripts/swap_apns_key.py installs it), (2) phone — TestFlight → open
  BUILD 29 → sign in once; device-watch announces each flip within 15 min.


## 2026-09-19 06:00 UTC (build-loop run) — PIPELINE FULLY GREEN: build 29 VALID + IN_BETA_TESTING with the day-one re-kick fix aboard; a four-run debugging chain traced the version-stamp break to its true root (xcodegen wrote literal CFBundleVersion=1 into Info.plist) and the Fastfile now verifies the stamp in-archive AND in-ipa

- Last run's assumption was WRONG and this run caught it: build 2 (tag
  ios-v21) had silently FAILED — "no upload row yet, normal" was actually a
  hard Swift compile error. Reading the real Actions run statuses (not the
  ASC poller alone) is now the loop's first step.
- Fix 1 — compile (run 35420950536): the re-kick commit's
  `private static let tokenKey` is MainActor-isolated, and the PushKit
  delegate is `nonisolated` → "main actor-isolated static property
  'tokenKey' can not be referenced from a nonisolated context".
  `private nonisolated static let` (immutable String, Sendable) is the
  correct repair; swift_sanity's required pin updated to the guarded form
  (and it NEGATIVE-tested the change: sanity failed until the pin matched).
- Fix chain — build numbers (runs 35423491270 → 35424281811 → 35424600305 →
  35424959129): build 3 archived fine but ASC rejected the upload with
  -19232 "bundle version must be higher than the previously uploaded
  version" — cfBundleVersion=1 again. Evidence-driven sequence: (a) explicit
  `manageAppVersionAndBuildNumber:false` in gym's exportOptions was NOT
  enough (gym appends xcargs to -exportArchive too); (b) lane rebuilt as
  archive-only (skip_package_ipa) + hand export with a generated
  ExportOptions.plist and zero build settings on the command line + loud
  guards — the ARCHIVE itself still carried CFBundleVersion=1;
  (c) MANAGE_APP_VERSION_AND_BUILD_NUMBER=NO on the archive — still 1;
  (d) TRUE ROOT CAUSE: xcodegen hardcodes CFBundleVersion=1 into the
  GENERATED Info.plist, and a plist literal overrides CURRENT_PROJECT_VERSION
  entirely (this also explains yesterday's "green" build 1 shipping as
  version 1 — it was never tested against a second upload). Plist now uses
  `$(CURRENT_PROJECT_VERSION)` / `$(MARKETING_VERSION)` references; the
  archive guard immediately PASSED (build 28 stamped). One self-inflicted
  typo (`xcrun -exportArchive` → `xcodebuild -exportArchive`) fixed, and
  ios-v27 (run 35425198930) went END-TO-END GREEN: upload row
  cfBundleVersion=29 COMPLETE, BUILD: 29 | VALID | IN_BETA_TESTING (count 2).
- Fastfile hardening that stays: 3-step lane (archive w/ stamp +
  MANAGE...=NO → hand export from clean plist → verify CFBundleVersion in
  the .xcarchive AND inside the exported .ipa, UI.user_error! on any
  mismatch), plus the beta lane prints the generated Info.plist every run so
  a literal-vs-reference regression is visible in CI. FASTLANE.md documents
  the whole trap chain with run ids. verify_all ALL GREEN after every change;
  sentinel 18/18; no gateway/bridge restarts.
- Live state: device_registered:false, push_ok:0, probe verdict still 403
  InvalidProviderToken. Build 1 is now superseded — NEEDS ENRIQUE updated to
  point at BUILD 29: (1) APNs-capable .p8 (scripts/swap_apns_key.py
  unchanged), (2) phone — TestFlight → open BUILD 29 → sign in once; the
  re-kick fix (now actually compiled + shipped) makes that single open+sign-in
  flip device_registered. Device-watch announces each flip within 15 min.


## 2026-09-19 04:30 UTC (build-loop run) — day-one registration seam closed in the app: PushKit token persisted + /register RE-KICKED the moment auth flips (login or manual token), so "open build 1 once" now actually flips device_registered instead of waiting for a second cold launch

- Audit this run (holding pattern; both blockers still Enrique-side) traced
  the day-one critical path end-to-end and found a real timing seam in
  CallManager: the /register retry loop (5 attempts, 2/4/8/16s backoff ≈ 30s)
  starts at LAUNCH — but a fresh install launches into Setup → Login, so all
  five attempts fire UNAUTHENTICATED (401s) and exhaust while the user is
  still typing credentials. The login round trip then takes minutes; without
  a re-kick the bridge never learns the PushKit token until the NEXT cold
  launch. Concretely: Enrique accepts the invite, opens build 1, signs in —
  and device_registered STAYS false, "ring this phone" is dead on day one,
  and the device-watch keeps announcing nothing. The exact flip the whole
  watch/sentinel apparatus is waiting on had a hole in it.
- FIX (3 files): (1) CallManager persists every PushKit token to
  UserDefaults (jarvis.push.voiptoken) BEFORE the first registration attempt
  — token rotation just overwrites + re-registers. (2) New
  retryDeviceRegistration() re-kicks /register from the STORED token; wired
  to RootTabView.task (fires exactly when isAuthed flips true via password
  login, and on cold-launch-already-authed) and to AuthStore.applyManualToken
  (Settings lives INSIDE the already-visible RootTabView, so its .task never
  re-fires — that route needs its own kick). Every attempt re-reads the
  CURRENT access token, so the re-kick lands the registration the moment
  auth exists. Server side already idempotent (/register upserts the token
  file) — bridge untouched, no restart.
- Proven: swift_sanity gained required-guard pins on all three pieces
  (tokenKey + persist + retryDeviceRegistration in CallManager, the .task
  hook in JarvisApp, the applyManualToken kick in AuthStore) and the pin was
  NEGATIVE-TESTED — tampering the symbol out of CallManager makes sanity
  exit 1 with "REQUIRED pin missing", restore makes it exit 0. No Swift
  toolchain here, so structural balance + pins + full verify_all (34+1 doc
  contracts, sentinel 18/18, live health, native WebRTC e2e vs the live
  gateway) are the verification stack; ALL GREEN after the change. Committed
  to master; next tag build (ios-v2) picks it up — no rebuild needed for
  build 1's verdict.
- SHIPPED THIS RUN (after the audit fix): tag ios-v21 pushed → ios-release.yml
  → build 2 carrying the re-kick fix (build number = GitHub run number, so
  build 1 does NOT contain it — relaunch was the old workaround, build 2
  removes the need). ASC poll ~16 min after the tag: no upload row yet —
  normal (yesterday's green cycle ≈ 90 min incl. runner + SPM + archive);
  next loop ticks re-poll; an itms code in the UPLOAD row = pipeline failure
  to diagnose. Live state unchanged: device_registered:false, push_ok:0,
  probe verdict 403 InvalidProviderToken, build 1 VALID + IN_BETA_TESTING.
  NEEDS ENRIQUE unchanged: (1) APNs-capable .p8 (scripts/swap_apns_key.py),
  (2) phone — TestFlight, invite, open build 1, sign in. Both flips announce
  within 15 min; with the app fix riding the repo, opening + signing in once
  is now genuinely sufficient for flip 2.


## 2026-09-19 03:50 UTC (build-loop run) — success-was-paged-as-a-loss seam closed in the watch-sentinel: GONE verdicts are now health-ARBITRATED (device_registered:true AND push_ok>=1 = QUIET stand-down), so the mission-complete self-remove can never fire a false "announcer lost" alert

- Audit this run swept for drift with both blockers still Enrique-side and
  found the next real seam — a false-positive alarm scheduled for the moment
  of SUCCESS: when the device-watch's endgame fires (real verification push
  accepted), it delivers MISSION COMPLETE and SELF-REMOVES. The sentinel's
  GONE branch treated "cron absent + bridge reachable" as a LOSS (alert once,
  stand down) — reachability alone cannot distinguish "watch removed because
  it finished" from "watch removed because something killed it". First real
  ring tonight would have paged the TF Ops group with a bogus "flip announcer
  is lost" line at the exact moment the mission completed.
- FIX (deployed LIVE this run, repo→live byte-identical): the GONE branch
  now reads /health as the ARBITER — MISSION_DONE = `device_registered:true`
  AND `push_ok>=1` (the exact shape the endgame leaves behind: phone
  registered + Apple ACCEPTED a real push) → QUIET stand-down, no alert;
  GONE with any lesser health while the bridge answers → the alert, with an
  honest message ("does NOT prove completion (need device_registered:true
  AND push_ok>=1)"); bridge unreachable → unchanged alert-once + stand-down.
  Uses push_ok, not push counters' absence — mirrors the watch's own
  fail-closed endgame semantics (a 200 round-trip is the only proof).
- Proven in the sandbox, not assumed: stub bridge made MUTABLE
  (Bridge.health dict) so the proven-completion branch is driven for real —
  B3p gone+PROVEN health → SILENT + stood-down flag; B3p-bis one-shot holds;
  B3 gone+UNPROVEN (registered:false, push_ok:0) → GONE alert fires with the
  new wording; B1–B13 regression all green → 18/18 PASS (was 15/15). The
  wiring pin + doc-contract step 10 gained the arbitration pin each
  ("GONE verdict is health-arbitrated"), so a revert cannot hide.
- Live tick after deploy: SILENT, exit 0 (today's state — watch present,
  22/384 ticks — takes the normal path; the new branch is inert until the
  real GONE). verify_all.sh ALL GREEN end-to-end after the deploy (34+1 doc
  contracts, sentinel wiring incl. new pin, behavior 18/18, watch wiring,
  bearer probes, gateway gate, live health, prod parity, native WebRTC e2e).
- Live state unchanged: probe verdict still 403 InvalidProviderToken (key
  unchanged), device_registered:false, push_ok:0/push_fail:0, schedule clean,
  build 1 VALID + IN_BETA_TESTING. Crons: loop 30m armed, guide 13:00 UTC
  armed, sunset 23:00 UTC armed, watch 15m armed, sentinel 30m armed.
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8
  (scripts/swap_apns_key.py installs it). (2) phone — install TestFlight,
  accept the invite, open build 1 once → /register fires. Either flip is
  announced within 15 min; with both, the watch proves delivery with a real
  push before mission-complete — and NOW the sentinel stands down silently
  instead of paging success as a loss.


## 2026-09-19 03:10 UTC (build-loop run) — delivery-channel integrity on the terminal wait: the two one-shot announcers (23:00 UTC sunset wrap-up, 13:00 UTC setup guide) were still aimed at the WhatsApp DM that 403'd three times on 9/18 — both repointed to the PROVEN Signal DM, prompts + mirrors pinned, sweep ALL GREEN

- Audit this run (holding pattern; features 1–8 done, waiting only on the two
  flips) found the seam: jarvis-ios-loop-sunset and
  jarvis-ios-apple-setup-guide delivered to `origin` = the WhatsApp DM, while
  the device-watch had already been moved to Signal (`signal:+130****2646`,
  firing ok every 15m since the channel switch, zero delivery errors). Had
  they fired as configured, tonight's FINAL mission wrap-up (including the
  loop pause + NEEDS-ENRIQUE list) would have vanished into a 403'd channel.
- FIXED live via `hermes cron edit`: deliver → `signal:+130****2646` (the
  exact target the device-watch proves with every 15m tick — no guessing at
  phone numbers), and both prompts updated to NAME the Signal target and
  FORBID WhatsApp delivery, so the agent-side "verify delivery goes here"
  instruction can't steer back to the dead channel. Repo mirrors
  (scripts/cron_prompts/*.txt) updated byte-identically; doc-contract step 8
  pins (live==mirror) re-verified PASS; full verify_all sweep ALL GREEN
  after the change. Sentinel/watch/loop crons untouched.
- Unchanged: device_registered false, push counters 0/0, probe still 403
  InvalidProviderToken. NEEDS ENRIQUE unchanged: (1) APNs-capable .p8
  (swap_apns_key.py installs it), (2) phone-side TestFlight install + open
  build 1. Both flips announce within 15 min via the watch; with both, the
  endgame proves real delivery before mission-complete.

- Gap this run found: after tonight's 23:00 UTC sunset pauses the build-loop
  cron, the 15m device-watch is the mission's ONLY autonomous announcer for
  the two remaining flips (APNs key accepted / phone /register) — and its
  own failure modes were all silent: cron removed or paused, ticks
  exhausted, scheduler stall, bridge :9160 down, or probe_apns_delivery.py
  broken (flip-1 detection blind). Any of these and Enrique's flips happen
  with nothing firing. (The watch's own endgame already proves delivery;
  this closes the "who watches the watch" seam.)
- SENTINEL (deployed LIVE this run): jarvis-ios-watch-sentinel —
  no-agent 30m cron, 720 ticks (~15 days), zero LLM cost — checks every
  tick: (1) watch cron exists (removed + bridge-unreachable = alert once
  then STAND DOWN: cannot tell mission-complete self-remove from a real
  loss; removed + bridge-reachable = alert once), (2) enabled, (3) ticks
  fresh (last_run_at age > 40m = stalled), (4) tick budget > 8 (~2h
  headroom), (5) bridge /health ok, (6) probe still emits a VERDICT.
  Alerts are one-line, latched per fault (re-arm on recovery), routed to
  the TF Ops group; failure channel suppressed (script always exits 0, so
  the cron failure path can never double-announce); strictly
  observe-and-report — it never invokes hermes (mentioning `hermes cron
  resume` inside an alert text is human remediation, not a mutation).
- PROVEN before deploy, not assumed: sandbox behavior test
  (check_watch_sentinel_behavior.py) drives the REAL script against a stub
  jobs.json + stub bridge + stub probe via JARVIS_IOS_* env overrides —
  15/15: healthy→silent ×2, gone→alert+stood-down, gone again→silent,
  paused→alert, persists→latched, fix+break→refires, stalled (50m-old
  last_run_at), budget (5 ticks left), bridge down, probe blind, 4-fault
  storm→4 lines, recovery→silent+re-armed. The test caught TWO real design
  bugs pre-deploy: the stall check originally compared last_run_at to the
  PREVIOUS POLL (a 50-min-stale tick that just changed would pass) — now a
  direct age-vs-now check; and the stood-down flag was a fixed /tmp path
  (sandbox would have touched the prod flag) — now state-file-relative.
- Pinned three ways so it cannot rot: check_watch_sentinel.py (18 wiring
  pins: repo/live byte-identical, executable, cron spec 30m/720,
  Ops-group deliver, local failure channel, no-hermes-invocation,
  always-exit-0, watch mirror still identical) +
  check_watch_sentinel_behavior.py (the 15-branch sandbox, re-run in every
  sweep) + check_doc_contracts.py step 10 (5 pins incl. ARCHITECTURE.md
  documents the layer). verify_all 5c-bis runs both; full sweep ALL GREEN
  end-to-end after the live deploy (34 doc-contract pins, sentinel wiring
  + behavior, watch wiring, bearer probes, gateway gate, live health, prod
  parity, native WebRTC e2e PASS).
- Live state after deploy: sentinel cron enabled (next run 02:48 UTC),
  live run SILENT (everything healthy), device-watch untouched
  (16/384 ticks, next 02:23, deliver pins intact), bridge /health clean
  (0/0 counters, device_registered false, last_push_error empty). Probe
  verdict re-confirmed live: still 403 InvalidProviderToken both legs
  (key unchanged).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8
  (scripts/swap_apns_key.py installs it, gates re-verify Apple's verdict).
  (2) phone — install TestFlight, accept the invite, open build 1 once →
  /register fires. Either flip is announced within 15 min; with both, the
  watch proves delivery with a real push before declaring mission complete.

## 2026-09-19 01:00 UTC (build-loop run) — push-success observability closed the mission-complete honesty gap: bridge counts real Apple round-trips (push_ok/push_fail on /health), the device-watch ENDGAME now PROVES delivery with a real verification call instead of asserting it; prod-path verified live, deploy executed via the safe path

- Close audit this run found the endgame seam: the watch's
  MISSION-COMPLETE message asserted "/call now rings the phone
  (pushed:true)" — a claim nothing had verified at that moment, and one
  /health field actively could not support: last_push_error=="" means only
  "nothing failed YET", never "a push succeeded". Bridge + watch + probes
  + docs upgraded together so the mission's final announcement is earned,
  not assumed.
- BRIDGE (deployed LIVE this run): `_bump_push_counters()` persists
  push_ok/push_fail to push_counters.json (0600, corrupt-file tolerant,
  best-effort — a counter write failure can never affect the push result);
  every REAL Apple round-trip bumps exactly one counter (200 → push_ok,
  transport error / non-200 → push_fail); the unconfigured and no-device
  early-exits are NOT counted (round-trip-only semantics — they never
  touched Apple); /health exposes both as ints. Shadow probe
  (scripts/probe_push_counters_shadow.py, stubbed Apple vs the REAL module,
  17/17) pins: transport→fail, 200→ok, 403→fail, both early-exits not
  counted, /health shape, corrupt-counters reset, 0600 perms. Wired into
  verify_all as step 1c.
- WATCH (live script replaced, byte-identical mirror): the
  both-flips-seen branch now reads push_ok BEFORE, fires a real
  verification call via scripts/call_enrique.py (production HMAC path,
  reason explains "ignore/hang up"), re-reads /health with retries, and
  declares MISSION COMPLETE only if push_ok incremented (Apple ACCEPTED
  the push). Fail-closed: any mismatch → LOUD URGENT line (routes to the
  TF Ops group via failure_deliver), state kept, cron NOT removed so the
  loop agent triages on its next run. The message also states the honest
  boundary: push_ok proves APNs accepted, not that CallKit rang — the
  manual ring test stays recommended. Whole block tested in a sandbox
  (stub bridge on :9163, stub call tool, fake hermes): 4/4 PASS — happy
  path (counter bump → mission complete + self-remove fired), call-tool
  failure, no-bump, spaced-JSON health. Sandbox testing caught TWO real
  bugs before they could ship: a state-file read of a variable nothing
  writes (dead "before" value) and a compact-JSON-only grep that would
  have read the REAL bridge's push_ok as empty (spaced JSON) and turned
  every real mission-complete into a false URGENT.
- PROD-PATH VERIFIED LIVE before deploying the watch: /register with a
  sacrificial token (device-watch paused first so no false REGISTERED
  announcement was possible) → real /call → APNs answered the known 403
  InvalidProviderToken → /call returned pushed:false (correct) AND
  /health showed push_fail:1 (the rejected round-trip counted). Live
  state then restored pristine: sacrificial DEVICE_TOKEN removed,
  counters reset to 0/0, LAST_PUSH_ERROR cleared, watch resumed. Bridge
  deployed per the safe path: py_compile (repo + venv) → LKG staged →
  restart → /health verified (counters 0/0, device_registered false).
- Incident found by the post-deploy wiring sweep, fixed this run:
  `hermes cron pause/resume` MANGLED the watch's deliver field
  (personal DM → TF Ops group), which would have sent mission announcements
  to the Ops group instead of Enrique. Restored via `hermes cron edit
  --deliver 'signal:+130****2646'`; check_watch_wiring ALL PINS HOLD after.
  (The pause was itself protocol — it made the sacrificial-token test
  provably unable to fire a false REGISTERED.)
- Docs + pins: API.md /health shape now documents push_ok/push_fail and
  the "last_push_error=='' ≠ delivered" rule; ARCHITECTURE.md lists
  push_counters.json; check_doc_contracts step 9 (7 new pins) holds the
  counter contract, the early-exit semantics, the watch's real-call
  endgame, its fail-closed shape, and the whitespace-tolerant extraction.
  verify_all ALL GREEN end-to-end after everything (30/30 doc contracts,
  swift_sanity, counter shadow probe, bearer probe 16/16, gateway gate,
  live health, prod parity incl. LKG==prod==repo, watch wiring,
  native WebRTC e2e).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8
  (scripts/swap_apns_key.py installs it; probe + swap gates re-verify
  Apple's verdict automatically). (2) phone — install TestFlight, accept
  the invite, open build 1 once → /register fires (CallManager retries
  with backoff). The device-watch (15m) announces either flip within 15
  minutes, and when BOTH land it will now prove the delivery path with a
  real push before declaring the mission complete.



- Full re-audit this run: backlog 1–9 complete, verify_all ALL GREEN
  (23/23 doc contracts, 15/15 watch pins, bridge bearer probe, gateway
  gate, prod parity, live health, native WebRTC e2e PASS). ASC build 1
  VALID + IN_BETA_TESTING; probe verdict re-run live: still 403
  InvalidProviderToken (key unchanged); device_registered false;
  last_push_error empty; schedule clean.
- This run's real delta is the loop itself: with both blockers
  Enrique-side and the dual-flip device-watch (15m, ~4-day lifetime,
  key_wait+device_wait announced once each) covering BOTH remaining
  events independently, the build loop at every 5m (~288 runs/day) was
  pure holding-pattern cost — the same proxy-cost class that paused
  backlog #7. Cut to every 30m via `hermes cron edit`, verified in
  jobs.json (interval minutes:30, enabled, next_run set); verify_all
  re-run ALL GREEN after the change (its cron step only pins
  enabled-state, correctly not cadence). Sunset job 23:00 UTC today
  still pauses the right job (c4b099e2cf11) and now sees flips with 30m
  granularity for its final ~16 hours — well within the watch's
  15-minute announcement latency.
- Commit 74892f5 pushed (empty-delta allowed so the ops change is on the
  record). NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the
  APNs-capable key (developer.apple.com → Keys → APNs CHECKED) and send
  the .p8 (one command installs it); (2) phone — install TestFlight,
  accept invite, open build 1 once → REGISTERED. Watch announces either
  flip within 15 min.

## 2026-09-19 00:00 UTC (build-loop run) — stale-guidance bug caught BEFORE it fired: the Sep-19 9AM setup guide claimed the broken APNs key works; prompts now mirrored + pinned; watch lifetime doubled to 4 days

- This run's own audit found the next scheduled message to Enrique was wrong:
  the `jarvis-ios-apple-setup-guide` cron (fires 9AM Miami Sep 19) still said
  "the push bridge is live with the APNs key" and FORBADE mentioning key
  creation — written at 21:20, BEFORE the 22:35 discovery that the key is
  ASC-only and Apple rejects its pushes (403 InvalidProviderToken). He would
  have installed build 1, failed the "ring this phone" test, and concluded
  the app is broken. Fixed: the prompt is now STATE-DRIVEN — it runs
  scripts/probe_apns_delivery.py + /health FIRST and includes the 2-minute
  key-creation step (developer.apple.com → APNs checked → send the .p8)
  ONLY if the verdict is still InvalidProviderToken; the ring-test section
  now says it works only AFTER the key lands.
- Same staleness class fixed in the sunset job (Sep 19 23:00): its wrap-up
  now builds the NEEDS-ENRIQUE list from live checks (probe verdict +
  device_registered) instead of hardcoded facts, and it explicitly leaves
  the device-watch running after pausing the build loop (previously
  unstated — the watch is what announces the flips after the loop stops).
- Prompt-drift is now a pinned contract: both prompts mirrored into the
  repo at scripts/cron_prompts/ (source-of-truth, same pattern as the
  gateway mirror) and check_doc_contracts.py step 8 machine-checks
  (a) live prompts byte-identical to mirrors, (b) state-driven shape
  (probe + /health present), (c) no "bridge is live with the APNs key"
  claim. 23/23 pins PASS.
- Device-watch lifetime doubled: 192 → 384 ticks (48h → ~4 days). Its
  expiry (Wed ~21:30 UTC) had silently drifted past the sunset deadline —
  if Enrique acted over the weekend, the KEY-LIVE / REGISTERED /
  MISSION-COMPLETE announcements would never fire. flip-1 detection
  re-verified through the exact production command path (/usr/bin/python3,
  "delivery path PROVEN" grep) — silent now, fires on the good-key
  verdict. check_watch_wiring.py delivery pins corrected to the actual
  watchdog convention (announcements → personal DM, failures → TF Ops
  group) — the old pin predated the convention and flagged the correct
  live config as FAIL.
- Verified live: verify_all.sh ALL GREEN (incl. 23/23 doc contracts, 15/15
  wiring pins, native WebRTC e2e vs the live gateway); live crons edited
  via `hermes cron edit` and re-read back from jobs.json (byte-identical
  to mirrors); bridge /health unchanged (device_registered:false,
  last_push_error:""); ASC unchanged (build 1 VALID + IN_BETA_TESTING).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8 (one
  command installs it); (2) phone — install TestFlight, accept invite,
  open build 1 once → REGISTERED. The 9AM guide now tells him both steps.

## 2026-09-18 23:55 UTC (build-loop run) — the push path's last unexercised link closed: transport guard in `_send_voip` + the probe now proves the BRIDGE'S OWN httpx+h2 stack (both-legs verdict), stale "egress mangles python h2" claim disproven and corrected

- Audit found the delivery chain had one link never exercised AND one
  fragile seam: (1) every probe/swap verdict was proven with **curl**, while
  the bridge's production push uses **httpx+h2 from its own venv** — which
  had never sent a single packet to Apple (every push so far early-exited on
  the empty DEVICE_TOKEN); a bridge-transport regression (missing h2
  package, egress change, venv breakage) would have hidden behind a
  curl-only green until the first real "call me". (2) `_send_voip`'s POST
  had **no try/except** — a transport exception would escape `/call` (which
  has no handler) as an unhandled 500 with NO `LAST_PUSH_ERROR` recorded;
  the scheduler path wrapped the same call, /call did not.
- LIVE EXPERIMENT first: the bridge venv's exact stack answered
  `HTTP 403 InvalidProviderToken, proto=HTTP/2` on BOTH APNs hosts — the
  production transport is healthy today, AND the old comments claiming
  "this box's egress mangles python h2 to Apple" (urllib-era artifact in
  probe + swap) are FALSE. Both comments corrected with the disproof date.
- Bridge hardening (deployed LIVE this run, repo main.py is the systemd
  ExecStart cwd): the POST is wrapped — transport failures now print
  `[bridge] APNs push TRANSPORT ERROR: <type>…`, record
  `LAST_PUSH_ERROR=transport <Type> at <ts>`, and return False; /call can
  never 500 at the transport layer again. Shadow-tested on the real module
  (stubbed Client raising ConnectError → False + recorded; empty-token
  early-exit unchanged; real 403 path still recorded; /health shape
  intact), py_compile OK, deployed per the safe path: LKG snapshot →
  idle-window restart 23:5x UTC (gateway quiet ≥5 min) → /health ok →
  real /call probe → journal line shape unchanged.
- Probe upgraded to a TWO-LEG verdict: leg 1 curl (portable), leg 2
  "BRIDGE-STACK" — the SAME dummy-token POST through
  /opt/jarvis-ios-bridge/venv's httpx+h2 client (the exact `_send_voip`
  transport). Provider token reaches the leg via environment variable
  (never argv — ps-readable); no second mint (Apple's token-churn rule).
  `400 BadDeviceToken` now requires BOTH legs to agree; a bridge-transport
  failure gets a distinct `BRIDGE TRANSPORT BROKEN` verdict (never a
  curl-only green pass; under --warn it still exits 0 so the cron sweep
  stays green until the key lands).
- Wire-up: check_doc_contracts step 7 pins the whole contract (leg present,
  token-via-env, both-legs verdict rule, transport-broken diagnosis,
  `_send_voip` guard); API.md documents the `transport …` error shape;
  BUILD.md documents the two-leg probe + guard. verify_all step 1b now
  runs the bridge-stack leg on every sweep.
- verify_all.sh ALL GREEN end-to-end after the restart (doc contracts incl.
  new step 7, swift_sanity, bearer probes, gateway gate, live health,
  prod parity, watch wiring, native WebRTC e2e PASS). Bridge /health
  `last_push_error:""`, device_registered:false, scheduled:0 — live key
  verdict re-confirmed unchanged (403 InvalidProviderToken, both legs).
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com → Keys → APNs CHECKED) and send the .p8 (one
  command installs it; the swap's gate 3 + the probe's both-legs verdict
  now cover the production transport too). (2) phone — install TestFlight,
  accept invite, open build 1 once → REGISTERED. First real ring = key
  swap + phone flip, both announced by the device-watch.

## 2026-09-18 23:20 UTC (build-loop run) — device-watch upgraded to DUAL-FLIP: now announces the APNs key flip the moment it lands, not just the phone flip

- Gap found: the watch only monitored `device_registered`. When Enrique's
  replacement .p8 lands and `swap_apns_key.py` installs it, NOTHING would
  announce it until the next manual probe or sweep — the single most
  anticipated event of the mission was silent. The watch now detects BOTH
  remaining flips, announces each once (state-file bits), and self-removes
  ONLY when both are set (either order): a phone that registers while the
  key is still rejected (pushes would 403) keeps the watch alive.
  - flip 1 (KEY LIVE): runs scripts/probe_apns_delivery.py per tick; exit 0
    (verdict 400 BadDeviceToken) == Apple accepts the installed key.
  - flip 2 (REGISTERED): /health device_registered, now whitespace-tolerant
    (REAL BUG found by the stub test: spaced JSON would have been missed).
- Flip paths PROVEN e2e this run: stub probe (verdict PROVEN) -> KEY LIVE +
  bit; stub :8799 health registered -> REGISTERED + bit; next tick ->
  MISSION COMPLETE + self-remove EXECUTED — using a SACRIFICIAL job name
  (jarvis-device-watch-selfremove-test) so the 21:50 mishap class (test
  copy deleting the real watch) is structurally impossible now. Real job
  verified untouched after the test; real state file untouched; leftover
  squatter stub on :8799 (from the 21:50 run, answering 501) found + killed.
- Deployed per the mirror workflow (repo -> cp -> pins): check_watch_wiring
  14/14 OK incl. byte-identical mirror; live tick verified (both WAIT lines
  once, then silent); doc contracts OK; verify_all ALL GREEN incl. native
  WebRTC e2e against the live gateway.
- Live state unchanged: probe still 403 InvalidProviderToken (key verdict
  re-confirmed live this run), build 1 VALID + IN_BETA_TESTING,
  device_registered false, last_push_error empty.
- NEEDS ENRIQUE (both unchanged): (1) web ~2 min — create the APNs-capable
  key (developer.apple.com -> Keys -> APNs CHECKED) and send the .p8; one
  command installs it (scripts/swap_apns_key.py) and the watch will
  announce KEY LIVE within 15 min. (2) phone — install TestFlight, accept
  invite, open build 1 once -> REGISTERED announced -> mission complete.

## 2026-09-18 22:55 UTC (build-loop run) — bad APNs key can no longer hide between sweeps: bridge remembers push rejections (`last_push_error` on /health), app + verify_all surface it

- Gap found: `_send_voip` logs a rejection once (journal line) and forgets.
  `/health` said `{apns_configured:true}` all evening while Apple was
  rejecting every push with `403 InvalidProviderToken` — the only witness
  was a 15-min sweep and whoever reads journals. A bad key that lands after
  any future swap/config drift would look "configured" between sweeps.
- Fix (deployed LIVE to the bridge this run):
  1. `_send_voip` now records every non-200 as `LAST_PUSH_ERROR=<code>
     <reason> at <ts>` in apns.env (0600, same store as DEVICE_TOKEN), and
     clears it on the first 200. Unconfigured path records `unconfigured`.
     No restart needed (env re-read per push, unchanged contract).
  2. `/health` exposes it as `last_push_error` (empty string = healthy).
     Live now: `{"ok":true,"apns_configured":true,"device_registered":false,
     "last_push_error":"","scheduled":0}` — empty is CORRECT until a device
     registers (the only real pushes so far took the no-device early-exit).
  3. App Home SYSTEM card prints `· APNs: <error>` when non-empty
     (HomeView + CCClient BridgeHealth field) — ships with the next tagged
     build, per the no-builds-for-cosmetics rule.
  4. verify_all step 4 now GATE-FAILS if /health names InvalidProviderToken
     (belt to 1b's WARN suspenders).
- Proven: shadow-tests on the real module with a stubbed APNs — 403
  InvalidProviderToken → False + LAST_PUSH_ERROR set; 200 → True + cleared;
  unconfigured → recorded; /call HMAC path unchanged (44024b5b pushed:false,
  skip line in journal). py_compile + TestClient /health/401-shape checks
  green; deployed per the safe path (repo→LKG /opt/jarvis-ios-bridge-lkg →
  idle-window restart 22:53 UTC → /health ok → real /call probe). Full
  verify_all ALL GREEN incl. native WebRTC e2e against the new process.
- docs: API.md /health shape, BUILD.md "APNs key status" (surfacing note).
- ASC unchanged: build 1 VALID + IN_BETA_TESTING. device_registered still
  false; probe still 403 (key verdict unchanged, now machine-visible).
- NEEDS ENRIQUE (both unchanged, one web + one phone): (1) create the
  APNs-capable key (developer.apple.com → Keys → APNs checked) and send the
  .p8 — agent-side install is one command (scripts/swap_apns_key.py);
  (2) install TestFlight, accept invite, open build 1 once → /register
  fires → device-watch announces → mission complete.

## 2026-09-18 22:55 UTC (build-loop run) — the one remaining agent-side gap closed: `swap_apns_key.py` turns the broken-key fix into ONE gated command; blocker verdict re-confirmed live

- Backlog 1–9 re-verified complete; verify_all ALL GREEN after this run's
  changes. Both open blockers remain Enrique-side (new APNs key, phone
  install) — so this run closed the last agent-side gap around the first one.
- Gap: when Enrique's replacement .p8 lands, installing it was a manual
  multi-step procedure (stage key → chmod → edit apns.env kid → keep the repo
  template in sync → re-probe). Each step is a chance to install a BAD key
  (e.g. another ASC-only key) over a broken one and only find out later.
  Fix: `scripts/swap_apns_key.py` — one command that refuses to touch the
  live bridge until the candidate key passes three gates: (1) PEM EC-key
  format, (2) actually signs an ES256 provider token, (3) **Apple's own
  verdict** — a dummy-token POST signed with the candidate must answer
  `400 BadDeviceToken` (same wire shape as probe_apns_delivery.py). 403
  InvalidProviderToken / 429 churn / network errors → hard refusal, live
  config untouched. On pass: installs 0600, updates the live apns.env kid
  AND the new tracked template `server/push_bridge/apns.env.example`
  together (repo↔prod kid can no longer silently disagree), with rollback
  on any mid-stage failure. Zero downtime: the bridge's `_send_voip`
  re-reads env per push, so NO restart is needed (`--restart` optional).
  Also refuses same-kid "swaps" (a NEW key has a NEW kid) and offers
  `--check` to gate the currently installed key anytime.
- Proven this run, no real key needed: refusal path against Apple LIVE
  (test EC key + correct kid-shape → gate 3 answered `403
  InvalidProviderToken` → SWAP REFUSED, live dir untouched, no staging
  debris); full happy path e2e against a local 400-BadDeviceToken stub
  (gates pass → staged into a throwaway state dir: key 0600, env kid
  rewritten, P8_PATH repointed; idempotence guard re-fires on a same-kid
  re-run). The sandbox regression risks (run_gates making its own live call
  beyond the stubbed one, pytest-free assert harness) were found and fixed
  during testing.
- Wire-up: doc-contract pins (check_doc_contracts.py step 6) now hold the
  whole contract machine-checked: gates present, refusals present, same-kid
  guard, rollback, BUILD.md naming the runbook. BUILD.md "APNs key status"
  + API.md "Pending" now say ONE command instead of a manual procedure.
- Re-verified live at 22:5x: the installed key STILL answers `403
  InvalidProviderToken` (nothing changed on Apple's side); bridge/gateway
  healthy, device_registered still false, schedule empty.
- NEEDS ENRIQUE (unchanged, both open): (1) web ~2 min — create the
  APNs-capable key (developer.apple.com → Keys → APNs checked) and send the
  .p8; agent-side install is now literally one command. (2) phone-only —
  install TestFlight, accept invite, open build 1 once → /register fires.
## 2026-09-18 22:35 UTC (build-loop run) — APNs delivery path PROBED for the first time: key is ASC-only, REJECTED by APNs (InvalidProviderToken) — new key = the one new NEEDS-ENRIQUE item

- Gap found and closed: `_send_voip` had only ever been exercised in its
  *unconfigured* branch (`pushed:false`, no p8). The p8 IS installed
  (apns_configured:true since 16:37 UTC) but no device ever registered, so
  Apple's verdict on the key itself was still unknown. New
  `scripts/probe_apns_delivery.py` mints the bridge's exact provider JWT
  (pyjwt ES256, kid header) and POSTs a syntactically valid, guaranteed-
  unregistered dummy token (DEADBEEF…9999) to the configured host.
  `400 BadDeviceToken` = everything healthy, no phone yet; anything else =
  named diagnosis.
- **THE FINDING: the live key (kid 2PMV4SF2LS) is REJECTED by APNs — both
  hosts answer `403 InvalidProviderToken` (production AND sandbox checked,
  iat skews 0/±5/±30 to rule out clock drift, curl + httpx + bridge's own
  stack). The same key signs ASC API calls fine (poller green all day;
  /v1/apps 200 re-verified this run). Diagnosis: the key was created in
  App Store Connect WITHOUT the "Apple Push Notifications service (APNs)"
  capability — ASC-only keys are accepted by api.appstoreconnect but not by
  api.push.** Ruled out: team ID (APNS_TEAM_ID 5ZXB95KW57 == ASC seed ID,
  confirmed via /v1/bundleIds), topic (== bundle ID), hosts, clocks, egress
  (raw h2 preface test to api.push.apple.com passes).
- Consequence, honestly stated: **until the key is replaced, NO VoIP push can
  be delivered.** The whole "pushed:false = just install TestFlight" story was
  incomplete — even with the phone registered, /call would still fail at
  Apple. Better to know tonight than on the first real "call me".
- NEEDS ENRIQUE (web, ~2 min; NEW, replaces nothing): developer.apple.com →
  Certificates, Identifiers & Profiles → Keys → create key WITH "Apple Push
  Notifications service (APNs)" checked → download the .p8 and send it to
  JARVIS (secret link is fine). Install + apns.env update + bridge restart +
  probe re-run are all agent-side; probe must then print
  `400 BadDeviceToken`. Documented in docs/BUILD.md "APNs key status" and
  docs/API.md "Pending".
- Bridge hardening (deployed live): `_send_voip` failure is now LOUD —
  non-200 logs `[bridge] APNs push REJECTED: HTTP <code> <reason>
  (topic=…, host=…)`; empty-token path gets its own distinct log line, so
  "no device" never masquerades as "APNs broken" again. Deployed per the
  safe path: py_compile OK → LKG snapshot (/opt/jarvis-ios-bridge-lkg/) →
  idle-window restart 22:22 UTC (gateway quiet ≥3 min) → /health ok →
  real /call probe prints the new skip line in the journal.
- verify_all: new step **1b/6 APNs delivery-path probe** (--warn mode so the
  cron sweep stays green while the key is pending; flip to gate mode once it
  reports BadDeviceToken). Full sweep ALL GREEN after the bridge restart,
  including bearer probe 16/16, gateway gate, prod parity, native WebRTC e2e.
- Housekeeping: one-off diagnostics cleaned from /tmp; probe caches its
  provider token 45 min @0600 (Apple's TooManyProviderTokenUpdates guards).
- NEEDS ENRIQUE (still open, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → device-watch announces. Key first,
  then the phone — both are on the critical path to the first real ring.
## 2026-09-18 22:00 UTC (build-loop run) — backlog #8 CLOSED: `call_enrique` is real — agent CLI shipped + voice-brain tool LIVE in the restarted gateway

- Gap found: #8's "WhatsApp/voice JARVIS call_enrique tool" existed only as a
  doc recipe — no JARVIS surface could actually ring the phone. Two parts
  shipped this run:
  1. `scripts/call_enrique.py` — agent-facing CLI over the bridge (call /
     schedule / list / cancel), self-signing HMAC, stdlib-only. Proven LIVE
     against the production bridge: schedule → list shows entry → cancel-one
     → list empty → call → `{pushed:false}` (no device registered yet, no
     side effects; `_send_voip` degrades to False with an empty DEVICE_TOKEN).
  2. `call_enrique` as a Pipecat function tool in the voice brain
     (/opt/voice-gw/brain.py; action=now|schedule|list|cancel, reason /
     at_iso / call_id; ISO-8601 validated;Miami-time echo on schedule;
     pushed:false → guidance to install TestFlight instead of dead air).
     Handler seam proven with all five paths against the live bridge before
     restart; "call me at 10am about X" now works hands-free mid-call.
- Deploy per ARCHITECTURE.md procedure: py_compile + venv import OK →
  last-known-good snapshot (brain+session) → restart at 21:55 UTC during an
  idle window (no offer/connect in prior 3 min; last call closed 21:45) →
  /healthz ok, brain realtime, openai ok → full verify_all.sh ALL GREEN incl.
  native WebRTC e2e against the NEW process.
- Repo mirrors synced: server/voice_gateway/brain.py (NEW — /opt/voice-gw was
  previously unmirrored in-repo) and session.py (picked up an unmirrored
  live-only presence fix from 17:34; /opt tree and repo now identical).
- docs/API.md: "Calling Enrique" section restructured — one-liner CLI,
  voice-tool note, raw curl recipe.
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → device_registered flips → every path above goes live
  (pushed:true, CallKit screen with reason).

## 2026-09-18 21:50 UTC (build-loop run) — device-watch flip path PROVEN end-to-end + wiring contract pinned; real watch restored after test mishap

- The one branch of the loop never actually exercised was the device-watch
  FLIP: what happens the moment device_registered turns true (announce +
  self-remove). Tested for real: stub HTTP server on :8799 answering
  device_registered:true, watch copy pointed at it → REGISTERED line printed
  AND `hermes cron remove` executed and deleted a cron job. The path works.
- COST OF THE TEST (owned): the copy kept the hardcoded JOB name, so it
  deleted the REAL jarvis-ios-device-watch. Restored in full same-run:
  15m × 192 repeats, script-mode (no_agent), deliver
  signal:group:Gd7ABv9… (TF Ops), id 67968b669507, state file reset to
  "wait", safe-tick verified silent. Live bridge /health confirms the test
  never touched real state (device_registered still false). Lesson encoded:
  the wiring is now machine-checked so this class of drift can't hide.
- Hardening: (1) self-remove failure is now LOUD — script prints a manual-
  removal WARNING to the Ops group instead of `|| true` swallowing it;
  (2) hermes invoked by absolute path /root/.local/bin/hermes (script
  runs from cron's minimal PATH); (3) live script mirrored byte-identical
  into the repo at scripts/testflight_device_watch.sh (same source-of-truth
  pattern as the gateway mirror; edit mirror → cp → verify_all).
- New scripts/check_watch_wiring.py (verify_all step 5c) pins the whole
  contract: script targets :9160 (not a stub), JOB pinned, cron exists/
  enabled/15m/192/script-mode, delivery = TF Ops group, repo mirror
  byte-identical, hermes CLI resolvable. 13/13 pins hold; full
  verify_all.sh ALL GREEN including the new step; doc contracts OK.
- BUILD.md watcher section updated: tested flip path, loud-failure note,
  mirror workflow. ASC unchanged: build 1 VALID + IN_BETA_TESTING.
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → watch announces → done.

- Re-verified: verify_all.sh ALL GREEN end-to-end (doc-contract pins, swift_sanity,
  bridge bearer probe 16/16, gateway bearer gate, live health bridge :9160 ok /
  gateway :9150 realtime:true / public /bridge/health 200, prod parity both units
  active + gateway mirror byte-identical, native WebRTC e2e PASS with hello+hangup).
  ASC state unchanged: build 1 VALID + IN_BETA_TESTING, no new uploads/rejections.
  Repo clean and in sync with origin/main; backlog 1–9 complete, no code delta.
- Cron-integrity audit (this run's addition): (1) sunset job's hardcoded pause
  target c4b099e2cf11 == the live jarvis-ios-build-loop id — tonight's shutdown
  will pause the right job; (2) device-watch script verified on disk at
  /root/.hermes/scripts/testflight_device_watch.sh and executes clean (silent
  wait-tick while device_registered=false, as designed); (3) 9AM guide cron
  verified telling Enrique build 1 only (no Xcode/upload mentions); (4) bridge
  schedule clean (scheduled:0), watch state "wait".
- device_registered still FALSE — waiting on the one phone-only step.
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → device-watch announces → done.

## 2026-09-18 21:20 UTC (build-loop run) — honesty pass: stale crons + docs corrected to the build-1 reality; nothing else to build

- Re-verified on this run: verify_all.sh ALL GREEN (fresh sweep, bridge 16/16,
  gateway gate, prod parity, live health, native WebRTC e2e PASS), doc
  contracts OK, ASC live state unchanged — build 1 VALID + IN_BETA_TESTING,
  no new uploads or rejections. Backlog 1–9 remains complete; no code delta
  found that survives the small-edit bar (the last cosmetic label already
  rides the next tagged build).
- THIS RUN'S REAL FINDING — stale guidance aimed at Enrique: the 9AM
  `jarvis-ios-apple-setup-guide` cron still told him to install **build 19**
  (an ITMS-rejected upload that never existed in TestFlight). Both it and the
  Sep-19 `jarvis-ios-loop-sunset` wrap-up predated the build-1 truth.
  Fixed via `hermes cron edit`: guide now installs **build 1** only (no
  Xcode/upload mentions); sunset wrap-up now ships the correct facts (build 1
  LIVE, CI does signed uploads, Enrique never touches Xcode) and checks
  bridge /health device_registered to choose mission-complete vs install
  steps. Both verified post-edit in jobs.json.
- Repo docs aligned to the same reality: README mission (3) — Enrique's only
  manual step is phone-side install, CI uploads headless; BUILD.md header now
  names build 1 as first SHIPPING build with the 19/20/21 ITMS-90683 history,
  and the watcher section is past-tense (build-watch self-removed after
  VALID; device-watch still armed on /health device_registered).
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → device-watch announces → done.

## 2026-09-18 21:05 UTC (build-loop run) — registration loop closed: device_registered on /health + self-removing watch; stale forge call cancelled

- Backlog re-verified COMPLETE (1–9): all code in HEAD, verify_all ALL GREEN
  after this run's changes (bearer probe 16/16, gateway gate, prod parity,
  WebRTC e2e PASS). TestFlight still: build 1 VALID + IN_BETA_TESTING.
- Registration loop closed (the last blind spot): bridge /health now returns
  `device_registered` (boolean — flips true the moment the phone POSTs
  /register; no token material). Verified live: `{"ok":true,"apns_configured":
  true,"device_registered":false,"scheduled":0}` after bridge restart.
- App: BridgeHealth decodes the new field; Home SYSTEM card shows
  "· device not registered" while it's false (same visible-not-silent contract
  as the APNs hint). Ships with the next tagged build — build 2 not burned for
  a cosmetic-only label while build 1 is still uninstalled.
- Watch armed: cron `jarvis-ios-device-watch` (15m, Ops group) prints REGISTERED
  + removes itself when the field flips; WAIT announced once, then silent
  ticks (state file /tmp/.jarvis_ios_device_watch_state); 192-repeat expiry.
- Housekeeping: cancelled the stale forge-validation scheduled call
  (acbfbcd4, was parked at 2030); bridge schedule now clean (scheduled:0).
  Removed dead empty ios/Sources/ tree. Doc-contract pins extended to cover
  the device_registered contract (check 5 in check_doc_contracts.py).
- NEEDS ENRIQUE (unchanged, phone-only): install TestFlight, accept invite,
  open build 1 once → /register fires → watch announces → mission complete.

## 2026-09-18 20:45 UTC (build-loop run) — TestFlight LIVE: build 1 VALID + IN_BETA_TESTING; "ingest stall" was ITMS-90683 all along

- ROOT CAUSE FOUND: builds 19/20/21 never "stalled in ingest" — they FAILED
  Apple asset validation with ITMS-90683 (missing NSCameraUsageDescription).
  Rejections never appear in GET /v1/builds; they are only visible in
  GET /v1/apps/6813590605/buildUploads (relationship earlier probes missed).
  The team-wide-sweep / agreement theories are dead; account is healthy.
- BUILD 1 IS LIVE: commit 2fed80a (camera purpose string) → CI run
  35391242548 uploaded 20:26 UTC → VALID at ~20:28 (90 s processing).
  buildBetaDetail: internalBuildState=IN_BETA_TESTING, autoNotify=true,
  export compliance pre-marked (usesNonExemptEncryption=false). Internal
  group "App Store Connect Users" auto-includes it — a manual betaGroups
  POST correctly 422s ("cannot be assigned to this internal group").
- Poller upgraded (scripts/poll_asc_builds.py): now also prints UPLOAD:
  lines (buildUploads validation state + ITMS codes) and a BETA: line
  (internal/external state, autoNotify) so a rejected upload can never
  masquerade as a stuck ingest again. Verified live: all three views green.
- docs/BUILD.md corrected: phantom ASC banner check removed; remaining
  step is phone-only. Watch cron (d6d31d5fec17) will see BUILD lines on
  its next 15m tick and self-remove as designed.
- NEEDS ENRIQUE (final, phone-only): install TestFlight, accept invite
  (enriquealonsorequejo@icloud.com), install **build 1**, open once →
  app POSTs /register → VoIP pushes live → mission complete.
- Full verify_all.sh suite unaffected (no server/gateway/app code changed
  this run — poller + docs only).

## 2026-09-18 20:05 UTC (build-loop run) — team-wide ASC ingest sweep: both apps frozen; ingest stall confirmed as account/key-wide

- New `scripts/asc_team_sweep.py`: pages ALL of /v1/builds (no app filter,
  newest-first, 4x100) and prints each app's most recent build + a MAX-AGE /
  VERDICT differential — answers "is ingest delayed team-wide or specific to
  our app?" in one shot, without hardcoding control-app IDs.
- Sweep result (20:05 UTC): only TWO apps exist on the account — 6813590605
  (EA's J.A.R.V.I.S, ours: ZERO builds) and 6773857468 (He Rose From Death,
  control). The newest build visible team-wide is HeRose build 20 uploaded
  **2026-08-21** → MAX-AGE 676h (>28 days). No app has ingested a build in
  >24h. VERDICT: team/account-wide ingest stall — NOT specific to our app.
- Cross-checked the independent preReleaseVersions index: ours EMPTY, HeRose
  shows only its Aug "1.0" record (matches). Builds 19/20/21 remain absent
  ~2h after the first upload (poll_asc_builds count: 0 at 20:00).
- Interpretation for Enrique's ASC-UI check (unchanged blocker, now sharper):
  whatever blocks ingest affects the whole account — most likely an ASSEMBLED
  agreement/licensing banner or Apple Developer Program license issue on the
  account in the ASC web UI; accepting it should flush BOTH apps. Diagnostic
  value: an app-specific problem is now ruled out.
- Full sweep unchanged: scripts/verify_all.sh ALL GREEN (bridge 16/16, live
  health ok, prod parity, native WebRTC e2e PASS, swift_sanity ok). Backlog
  1-9 remain complete; repo clean, in sync with origin/main.
- NEEDS ENRIQUE (unchanged): ASC UI check at appstoreconnect.apple.com →
  accept any agreement/banner (account-wide) + phone-side TestFlight
  install/open (reminder cron fires 9AM Miami Sep 19).

## 2026-09-18 20:20 UTC (build-loop run) — deeper ingest probe: uploads verified green, app record still EMPTY; agreement accepted (betaLicenseAgreement OK)

- Pulled the full Fastlane log for CI run 35383128608 (build 21, 18:58 UTC):
  "Successfully uploaded package to App Store Connect" + "fastlane.tools
  finished successfully" — the upload path is 100% clean, ASC_KEY_ID/
  ASC_ISSUER_ID/ASC_KEY_P8 secrets are correct.
- New API probes (all with the working ASC key):
  - GET /v1/apps/6813590605 → app exists, but EVERY relationship is EMPTY
    (builds, buildUploads, preReleaseVersions, betaAppReviewDetail, ...).
  - Direct builds rel (/apps/6813590605/builds): total 0.
  - betaLicenseAgreements?filter[app]=6813590605 → EXISTS (accepted-by-default
    shape; agreementText null) — no pending license agreement visible via API.
  - betaGroups: internal group "App Store Connect Users" EXISTS (created
    17:01 UTC today), matches control app's structure.
  - betaAppReviewSubmissions?filter[app]: HTTP 400 (odd, but non-blocking).
  - Account-wide builds (no filter, all pages): exactly 6 builds, ALL
    HeRose. Uploads from today (19/20/21) never became build records.
- Conclusion: ingest stall confirmed at the ASC ingestion layer for this app
  record, 80+ min post-upload, while the account/key/auth surface is fully
  functional. API cannot see WHY — the only visibility left is the ASC web UI
  (agreement banner, or an ingest error shown on the TestFlight tab).
- NEEDS ENRIQUE (unchanged + sharpened): sign in at
  appstoreconnect.apple.com → EA's J.A.R.V.I.S → TestFlight tab → look for a
  banner or error, accept anything pending. If clean, contact Apple
  Developer Support (ingest stuck >4h for 3 uploads while control app ingests
  fine on the same key).
- Poller/watch unchanged: testflight-build-watch cron keeps pinging every 15m;
  verify_all.sh ALL GREEN re-confirmed this run (bridge 16/16, WebRTC e2e PASS).
\n## 2026-09-19 ~18:40 UTC (build-loop run) — the device-watch ENDGAME is now behavior-proven BEFORE it can fire in prod: scripts/check_watch_endgame.py drives the REAL watch script through both flips, the mission-complete verification call, and the self-remove in a full sandbox (fake bridge/probe/call/hermes); the suite caught a REAL prod bug pre-emptively — a failed endgame would have re-fired a REAL call + URGENT every 15 minutes forever — fixed with a fires-once latch, verify_all 5c-ter

- Run-start sweep: verify_all ALL GREEN — ship gate still ios-v28 -> run #30
  -> build 30 VALID + IN_BETA_TESTING (no app-code change this run, no new
  tag — zero user-facing delta). Bridge :9160 healthy, apns_configured:true,
  device_registered:false (phone-side blockers unchanged). Watch + sentinel
  both ticking (18:15/18:18 outputs silent = healthy).
- The gap this run closed: backlog closed at 15:00, so this run audited what
  happens AFTER Enrique's two blockers land. The device-watch — the ONLY
  announcer left after tonight's 23:00 sunset — had NEVER been executed: its
  endgame block (both flips -> read push_ok -> fire a REAL verification call
  via call_enrique.py -> push_ok must increment -> self-remove the cron) would
  have run for the first time ever at flip time, untested, in prod. Reading it
  closely also found a REAL BUG: on a failed verification the comment claimed
  "fires once", but the state bits stayed set and NOTHING gated a retry —
  every 15m tick would have re-fired a real ring to Enrique's phone + a
  fresh URGENT, indefinitely.
- Fix (watch, prod-default-preserving): the endgame is now gated by an
  `endgame_tried` state latch, written BEFORE the call fires — attempt
  happens exactly once; a retry requires the loop agent to clear the latch
  deliberately after triage, never an automatic 15m re-fire. Whole script
  env-parameterized (WATCH_STATE / WATCH_BRIDGE / WATCH_PROBE / WATCH_CALL /
  WATCH_HERMES, prod defaults unchanged when none set) so the suite can drive
  the REAL script — testing a copy would prove nothing about prod.
- NEW scripts/check_watch_endgame.py (verify_all step 5c-ter): sandbox
  doubles = HTTP fake bridge (controllable device_registered + push_ok, POST
  /__fire__ = an accepted push), python-based fake probe/call/hermes; 23/23
  behavioral assertions: T1 first-tick WAIT announcements (once) + later
  ticks silent + no call before flips; T2 both flips -> KEY LIVE +
  REGISTERED + MISSION COMPLETE, exactly one call, push_ok delta seen, cron
  self-removed, state file consumed; T3 stuck push_ok -> URGENT, cron stays;
  T4 call fails -> URGENT, one attempt; T5 latched tick silent, one call
  ever; T6 half-flip -> announcement, no endgame; T7 latch holds even when
  inputs later go green (no second MISSION/removal). --selftest 4/4 mutates
  throwaway copies: latch removed -> T5 bites (S1), blind probe -> suite
  fails (S2), blind health-grep -> T2 bites (S3), clean copy green (S4).
- The strict harness bit its author three times before first green (same
  pattern as every checker in this ladder): the fake call double was #!/bin/sh
  but the watch invokes it via /usr/bin/python3 (prod's call_enrique.py is
  Python) — it died with a SyntaxError and silently no-opped; the probe
  double had the same defect; and two suite premises were wrong (first-tick
  WAIT announcements are BY DESIGN once, and MISSION COMPLETE deletes the
  state file, so "bits set" and "second tick silent" assertions had to model
  that). All recorded in the suite header.
- Synced the cron's EXECUTED copy at ~/.hermes/scripts/testflight_device_watch.sh
  (diff-proven identical) — the cron runs the hermes copy, not the repo's; a
  repo-only fix would have shipped nothing. Full verify_all ALL GREEN with
  5c-ter aboard (now 5 selftest suites: sentinel 18/18 + endgame 23/23 + 4/4).
- NEEDS ENRIQUE unchanged (three, all phone/web-side): APNs-capable .p8 via
  `scripts/swap_apns_key.py`; install the HIGHEST TestFlight build (30) and
  sign in once (device_registered must flip true); re-register his personal
  Signal account (DM bounces UNREGISTERED_FAILURE; groups deliver).
