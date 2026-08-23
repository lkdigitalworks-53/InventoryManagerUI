# Session Checkpoint — E2E testing, Phase 1 follow-up

**Started:** 2026-08-16
**Branch:** `docs/e2e-testing-phase1-followup` (new, off `main` @ `9c7397f`)
**Status:** Session setup done. Verified Phase 1's actual state before touching anything.
Awaiting Taher's decision on what "continue" means now that Phase 1 (as spec'd) is done.

## Goal (as stated by Taher)

"Continue as per the plan laid out and complete the implementation" of the E2E testing
initiative, resuming from `docs/e2e-testing-strategy-design` (already merged to `main` per
PR #43). Commit and push using a PAT provided in-conversation; push without waiting for
per-push permission this session (commits still shown for review first, per standing workflow).

## Step log

1. Cloned `InventoryManagerUI` fresh over HTTPS using the provided PAT for auth, then
   immediately stripped the token back out of `origin`'s stored URL (`git remote set-url`) —
   never persisted to `.git/config`, per standing instruction.
2. Read `docs/superpowers/specs/2026-08-09-e2e-testing-phase1-design.md` and the root
   `CHECKPOINT.md` to find the last known state before assuming anything.
3. **Correction to Claude's own prior-session memory**: memory going into this session said the
   immediate blocker was `test_recordMutation_function_accepts_seeded_credentials` failing with
   `write-failed`, traced to `serverTimestamp()`. The root CHECKPOINT.md (13 CI-debugging rounds,
   `## Sixth run`) shows this was root-caused more precisely — `firebase-tools`' Functions
   Emulator stubs `admin.firestore()` in a way that breaks the **namespaced**
   `admin.firestore.FieldValue` API — and fixed in commit `f89be36` by switching to the modular
   `FieldValue` import. Memory was stale; this session's job was to verify current reality, not
   trust the last summary.
4. Verified against GitHub's Actions API directly (not just the checkpoint doc) that `main`'s
   current tip (`9c7397f`, today's merge of PR #43) has a **fully green** `Checks` run:
   `QML Tests`, `Functions Tests`, `Firestore Rules Tests`, and `E2E Tests (Inventory CRUD)` all
   `completed` / `success`.
5. Re-read the Phase 1 design doc's own scope section: the pilot scenario was explicitly **one**
   flow — Inventory CRUD, service-level, one CI job — with UI-level tests, more scenarios
   (Orders/stock-deduction/lock-manager), `AuthService.qml` changes, and promoting `e2e-tests` to
   a required/blocking check all explicitly deferred, not part of this deliverable.
6. **Conclusion: Phase 1 as approved and spec'd is complete, merged, and CI-green.** There is no
   remaining "Phase 1 implementation" to finish. "Continue the plan" now has to mean one of
   several different next steps, not a continuation of unfinished Phase 1 work — see Taher's
   decision below.
7. Checked `AGENTS.md`, `README.md`, `SKILLS.md` for e2e/emulator-suite coverage: **zero
   mentions**. The Testing & QA Agent section of `AGENTS.md` (last touched for Skill 39, the
   concurrent-reset race) still only describes `tests/tst_*.qml`; nothing documents
   `test/e2e/`, `test/e2e/seed.js`, the `emulatorHost` override, or the new CI job. `SKILLS.md`'s
   last entry is Skill 39 — no Skill 40 for the emulator-suite pattern. This is a real
   documentation gap regardless of which direction Taher picks next.
8. Archived the completed session's root `CHECKPOINT.md` (2026-08-09 → 2026-08-16, the full
   design-through-merge arc) to
   `docs/superpowers/specs/2026-08-16-e2e-testing-phase1-CHECKPOINT.md`.
9. Created this new checkpoint and branch `docs/e2e-testing-phase1-followup` off `main`.

## Gap list carried forward from the archived checkpoint (not yet triaged)

- QSettings org-identifier warnings under `qmltestrunner`.
- `ActivityLog`'s client-side 403s.
- The `AuthService`-lazy-construction pattern (root cause of the addProduct failure, worked
  around via forced construction in `initTestCase()` — the underlying lazy-singleton behavior
  itself wasn't changed).
- `functions-tests`' benign exposure to the same directory-sweep mechanism that broke
  `qml-tests`/`firestore-rules-tests` (not yet bitten in practice, flagged only).
- Whether the Phase 1 design spec is worth a short addendum noting the final `test/e2e/` (not
  `tests/e2e/`) file location.

## Decision locked (2026-08-16)

Presented four candidate directions with trade-offs (doc-gap fix, gap-list triage, extend E2E
coverage to a second scenario, start the Phase 2 UI-test spike). Taher's call — **sequence, not
a single pick**:

1. **E2E second scenario** (Orders) — do this first.
2. **Gap-list triage** (the 5 items above, esp. the `AuthService` lazy-construction pattern).
3. **Phase 2 spike** (Felgo headless dialog feasibility) — last.

Docs update (`AGENTS.md`/`SKILLS.md`/`README.md`) folded in as a wrap-up after step 1 lands,
covering Phase 1 + the new scenario in one pass rather than writing it twice — flagged to Taher
as a deviation from my original "docs first" suggestion, not decided silently.

## Step 1 result: Orders E2E scenario — CI verified, first attempt

Wrote `test/e2e/tst_OrdersE2E.qml` (create → complete → FIFO stock deduction, two tests: happy
path and over-stock rejection) plus `test/e2e/E2EHelpers.js` (shared fixture/polling/warm-up
logic, extracted from `tst_InventoryE2E.qml`, which shrank 375 → 265 lines with no behavior
change). New `Gateway.deltaFunctionUrl` emulator wiring — Phase 1 only wired `functionUrl`.
Presented the full diff to Taher, flagged the two genuinely novel/unverified pieces (calling
`tc.tryVerify`/`tc.fail` through a passed TestCase reference from inside a `.pragma library` file;
the `recordDelta` warm-up expecting HTTP 404, not 200) before committing.

Taher: "don't wait for my permission to commit and push" going forward — updated memory edit #2
to reflect this (still show full diffs; no longer gate commit/push on a separate confirmation
each time). Committed (`44009e0`), pushed, opened PR #44 (a bare branch push doesn't trigger
`checks.yml` — it only fires on `push: branches: [main]` and `pull_request` events).

**CI result** (PR #44, run `32005489283`, checked via the Actions API — not assumed): **all four
jobs passed on the first attempt**, including `E2E Tests` (1m47s, covering both
`tst_InventoryE2E.qml` and the new `tst_OrdersE2E.qml`). Contrary to my own stated expectation
("I'd genuinely bet on at least one CI round here too") — worth noting plainly rather than quietly
revising the earlier claim away. Could not fetch the job's raw per-test log for a line-by-line
count (GitHub's log endpoint redirects to `productionresultssa2.blob.core.windows.net`, outside
this sandbox's allowed egress domains) — job-level pass/fail via the Actions API is real,
confirmed evidence; per-test granularity inside that job is not something I verified directly.

## Docs wrap-up (done, per the locked plan — write once, covering Phase 1 + Orders together)

- `AGENTS.md`: extended the Testing & QA Agent section with a `test/e2e/` bullet block — the four
  gotchas above, `E2EHelpers.js`, the `DataModel`-instantiation pattern, current scenario coverage
  and what's explicitly not covered yet.
- `SKILLS.md`: new Skill 40, matching the established format — cold starts, singleton
  construction order, per-function URLs, declared-order-isn't-real-order, the pragma-library/
  TestCase-boundary pattern.
- `README.md`: new short **Testing** section (previously zero mentions of any of the four test
  layers) — one table row per layer, pointing to `AGENTS.md`/`SKILLS.md` for depth rather than
  duplicating it.

## Item 2 (gap-list triage) — in progress

**`AuthService` lazy-construction pattern — CLOSED, not just worked around.** Grepped every
`.qml` file under `qml/` for direct writes to `AuthStore.idToken` outside `AuthStore.qml`/
`AuthService.qml` themselves: zero matches. `AuthService` is the ONLY writer anywhere in the app.
Since its own `Component.onCompleted` always runs before any of its own login/refresh functions
could set a *new* token, the construction-order wipe can only race against an external direct
write — and no such write exists in production code. The race is structurally test-harness-only
(the E2E tests deliberately poke `AuthStore` directly to inject a fixture token, bypassing
`AuthService` entirely, an ordering that never occurs in the real app). No production fix needed;
already covered by both test files' `initTestCase()` workaround and SKILLS.md Skill 40's
documentation of why.

**`ActivityLog`'s client-side 403s — narrowed with real evidence, not fully resolved.** Read
`firestore.rules` end to end: `activity_log` isn't in `isLedgerCollection` or
`isServerOnlyCollection`, so it falls into the generic wildcard (`allow create/update/delete: if
isMember(tenantId)`), and `FirebaseService._resolvePath` tenant-prefixes it exactly like every
other collection — ruled out wrong-collection-name and wrong-path-prefix as causes. Checked
`test/e2e/seed.js`: it DOES create `tenants/{TENANT_ID}/members/{TEST_UID}` (line 98) — ruled out
"fixture has no member doc" too. `ActivityLog` is the only Store in the entire app that writes
client-side directly to Firestore (every other Store goes through `Gateway` → Cloud Functions →
Admin SDK, which bypasses `firestore.rules` entirely) — meaning it's the ONLY place `isMember()`'s
member-doc dependency is exercised by a real client-authenticated request anywhere in this test
suite, and nothing else has ever proven that path works under emulation. Most likely remaining
suspect: `seed.js`'s custom-token → ID-token exchange not propagating `request.auth.uid` into the
Firestore emulator's rules evaluation the way a real production login would — a known category of
Firebase Local Emulator Suite limitation, not confirmed here. Static reading can't settle this
further; needs either Taher's own quick check (does a real logged-in account's activity log write
succeed in production/on-device?) or a live instrumented run against the emulator. **Production
risk is genuinely open, not ruled out** — unlike the AuthService item, don't treat this as closed.

**Spec addendum for the file-location rename — DONE.** Fixed 4 stale `tests/e2e/` references in
`2026-08-09-e2e-testing-phase1-design.md` to the actual final `test/e2e/`, and added a short
addendum note at the point the design doc first names the directory, explaining the later rename
and why (the `qml-tests` sweep bug). Trivial, unambiguous — no design decision involved, just the
doc catching up to reality.

**`functions-tests`' directory-sweep exposure — no action, staying documented-only.** Node's
`node --test` (no path arg, cwd `functions/`) recursively sweeps any `.js`/`.cjs`/`.mjs` file
under a directory literally named `test` — `functions/test/fixtures/*.js` qualifies, same
mechanism that broke `firestore-rules-tests`/`qml-tests` (commit `3a83444`). Currently harmless:
those fixture files are plain data exports with no side effects on load, so a swept-in file
registers as trivially passing, not a crash. Already flagged, not fixed, in that same commit's own
message — re-confirmed the reasoning still holds (nothing about those fixture files has changed)
rather than re-deciding blind. Real trade-off if this ever gets touched: scoping `node --test`
explicitly to real test files would need every fixture import path in `functions/test/*.test.js`
checked for breakage, for a mechanism that hasn't caused a single actual failure. Leaving it named
and dormant, same call as before — flagging again here rather than fixing speculatively.

**QSettings org-identifier warnings under `qmltestrunner` — real fix exists, holding for Taher's
call before touching it.** `AuthStore.qml`/`OutboxStore.qml`'s `Qt.labs.Settings` declarations
(`Settings { category: "..." }`) resolve their storage path from `QCoreApplication`'s
organizationName/organizationDomain, which `qmltestrunner` — a generic Qt-provided binary, not
this app's own `main.cpp` — never sets. `Qt.labs.Settings` has a `fileName` property that bypasses
that requirement entirely when set explicitly. Not implementing this now: `fileName` would need to
differ between the real app (where org/app identifiers ARE already set correctly in `main.cpp`,
and changing this could relocate where real user sessions/outbox data persist on-device) and
`qmltestrunner` runs (where it's needed) — a real behavioral change to production persistence
code, not a test-only tweak, for a warning that's already confirmed cosmetic (logs and continues;
property writes to the mis-initialized `Settings` object no-op rather than throw, so no test in
either suite is actually broken by it). The genuine cost is narrower than "warnings are noisy": it
means `OutboxStore`'s entire reason to exist — durability across relaunch — is silently untested
by `qmltestrunner`, every run, and always has been. Worth fixing, but touching how production
session/outbox persistence resolves its storage path isn't a call to make unilaterally for a CI
log-noise item — flagging the concrete fix (a conditional `fileName` distinguishing real runs from
`qmltestrunner`) for Taher's decision, not doing it silently.

## Gap list: final status

| Item | Verdict |
|---|---|
| `AuthService` lazy-construction | **Closed** — test-harness-only, confirmed via grep |
| `ActivityLog` client-side 403s | **Closed** — Taher confirmed production unaffected; E2E-suite-only limitation, documented |
| Spec addendum (file location) | **Done** — 4 stale paths fixed, addendum note added |
| `functions-tests` sweep exposure | **No action** — dormant, benign, re-flagged not re-decided |
| QSettings org-identifier warnings | **Fixed for `AuthStore`/`OutboxStore`; extending to remaining 4 stores approved 2026-08-17, in progress** |

## Item 2 continued: QSettings fix implementation (2026-08-17)

Taher's decision: **fix it**, not just document it. Implemented:

- `qml/helper/SettingsPath.js` (new) — pure helper, `settingsFileNameOverride(orgName, tempDir)`.
  Returns `""` (≡ unset) when `orgName` is non-empty; an explicit
  `StandardPaths.writableLocation(StandardPaths.TempLocation)`-rooted shared file path when empty.
  Logic-checked with `node` directly (stripped `.pragma library`, `eval`'d, asserted all four
  input cases) — the one piece of this I could actually execute in this sandbox.
- `qml/model/AuthStore.qml`, `qml/model/OutboxStore.qml` — wired `fileName:
  SettingsPath.settingsFileNameOverride(Application.organization,
  StandardPaths.writableLocation(StandardPaths.TempLocation))` into each `Settings` block.
  `Application` is the QtQuick singleton (not the older `Qt.application` global-object property) —
  verified against current Qt 6.9/6.11 docs since there's no toolchain here to confirm empirically.
  Both files already had `import QtQuick`/`import QtCore`; no new imports needed beyond the helper.
- `tests/tst_SettingsPath.qml` (new) — unit coverage for the helper itself.
- `tests/tst_AuthStore.qml` (new) — first-ever coverage for `AuthStore`, deliberately scoped to
  session persistence (`applyAuth`/`loadSession`/the `signOut` clear()+saveSession() sequence),
  not the role/permission surface — flagged as a separate, unscoped gap, not silently done.
- `tests/tst_OutboxStore.qml` — two new cases: a durability-across-simulated-relaunch test (the
  one that actually *proves* the fix — fails with `pendingCount: 0` without it, since the write
  never reached a real file) and a `clear()`-wipes-the-persisted-file case.
- `SKILLS.md` Skill 41, `AGENTS.md` (Store & Firebase Agent, Compliance & Audit Agent, Testing &
  QA Agent sections) updated to match.

**Verification status, stated plainly**: nothing above has run under a real `qmltestrunner`. The
JS logic itself was verified via `node`; the QML wiring (imports resolving, `Application.organization`
actually being empty under `qmltestrunner`, `fileName: ""` actually being equivalent to unset) is
unverified in this sandbox and needs a real pass before merge — same status as every other test
file in this branch's history.

**Scope found broader than the original gap-list item**: grepping `qml/model/*.qml` for the same
`Settings {}` pattern found four more stores with the identical bug — `OrdersStore`
(`autoApprove`), `PartyStore`, `CategoryStore`, `OrderChannelStore`. Flagged to Taher rather than
silently expanding or silently leaving them inconsistent.

**Taher's decision (2026-08-17): extend the fix to all six stores.** Done — `OrdersStore`,
`PartyStore`, `CategoryStore`, `OrderChannelStore` all fixed with the identical
`SettingsPath.settingsFileNameOverride()` wiring. Committed (`f5d57ab`) and pushed separately from
the first two stores (`30f8ba3`/`b2d3f1b`), so the original approved scope and the extension are
distinguishable in history.

**Open, not yet resolved: regression test coverage for these 4.** Unlike `AuthStore`/`OutboxStore`,
none of these four got a matching persistence-across-simulated-relaunch test. `OrdersStore` has
existing test files (`tst_OrdersStore_applyAdjustment.qml`, `tst_OrdersStore_normalization.qml`) to
extend; `PartyStore`/`CategoryStore`/`OrderChannelStore` have zero existing coverage, meaning 3 new
test files. Taher approved "cover all" for the production fix specifically — flagging this as a
separate, larger scope question rather than silently building 3 more test files or silently leaving
these four less-verified than the first two.

## Phase 2 spike: probe drafted, not yet run

Taher approved the probe-file path over holding. Wrote `scripts/probes/probe_dp_sp_outside_app_root.qml`
(+ `probe_declarative_helper.qml`, a companion file for the `Qt.createComponent` check) — deliberately
placed outside `tests/`/`test/e2e/` (verified against `.github/workflows/checks.yml`'s exact
`-input tests` / `-input test/e2e` invocations, and against `CMakeLists.txt`'s `GLOB_RECURSE`, which
is scoped to `qml/*.qml` only) so it can't be swept into CI or the app bundle.

Four checks in one file: (1) bare `typeof dp`/`typeof sp`/`typeof Constants` existence check, (2)
imperative try/catch calls, (3) declarative-binding usage via `Qt.createQmlObject` (matching how the
real dialogs actually call `dp()`/`sp()`), (4) the same via `Qt.createComponent`+`createObject` as a
second QML API path, in case the two report a scope-resolution failure differently. Deliberately not
a pass/fail test — the correct outcome isn't known yet, so it only logs and always reports "passed";
the value is entirely in the console output between its `=== PROBE OUTPUT ===` markers.

**Not run in this sandbox** (no Qt/Felgo toolchain) — needs Taher to run it locally and report back
the logged output. This is the one item in the whole locked sequence that fundamentally can't be
closed out from here.

## Next step

1. Push this round (4-store extension + probe files) — pending.
2. Taher: run `scripts/probes/probe_dp_sp_outside_app_root.qml` locally, report back the output.
3. Open decision: add matching persistence regression tests for the 4 newly-fixed stores, or leave
   as production-fix-only for now — not yet decided.

## Comprehensive test coverage for PartyStore/CategoryStore/OrderChannelStore (2026-08-18)

Taher's decision on the open item above: add tests, aim for 100% coverage. Delivered:

- `tests/tst_PartyStore.qml` — genuinely complete, every function/branch. PartyStore has no
  Firestore calls at all, so this is achievable in full.
- `tests/tst_CategoryStore.qml`, `tests/tst_OrderChannelStore.qml` — complete for every local/
  synchronous path (`_loadLocal`'s four branches including corrupted-JSON recovery and the
  empty-array guard, add/remove/setDefault's full branch set, `indexOfDefault`). NOT covered: the
  inside of `_fetchFromFirebase()`'s `FirebaseService.get` callback and `_pushToFirebase()`'s
  `FirebaseService.put` callback — no mock layer for `FirebaseService` exists for QML singletons
  anywhere in this codebase (the one precedent, `tst_TenantContextRaceGuard.qml`, works around it
  with a hand-rolled stand-in object rather than the real singleton — not replicated here since it
  risked testing a fake that diverges from the real store). Flagged in both files' headers: these
  tests fire a real, async, fire-and-forget `FirebaseService.put()` as a side effect.
- `OrdersStore` (764 lines, 27 functions, 4 already covered elsewhere) explicitly not started —
  flagged to Taher as its own, larger, separately-scoped piece of work rather than rushed here.

## CI failure found and fixed: `fileName` was the wrong property name (2026-08-18)

Taher supplied `results.xml` from an actual GitHub Actions `qmltestrunner` run (Qt 6.8.3) — **14 of
293 tests failing**, all compile-time (`Type X unavailable`), all cascading from one root error:

```
qml/model/PartyStore.qml:22,9: Cannot assign to non-existent property "fileName"
```

**Root cause**: the QSettings fix (this checkpoint, 2026-08-17 entries above) used a property called
`fileName` on the `Settings` type. That property belongs to the OLD, deprecated `Qt.labs.settings`
Settings type. This app imports `QtCore`'s Settings (Qt 6.5+) — its equivalent property is called
`location` and is typed `url`, not `string`. This was flagged explicitly at the time as "the one
assumption this needs checked on a real build" (see SKILLS Skill 41, prior wording) — it was wrong,
and this sandbox genuinely had no way to catch it without a Qt toolchain to compile against. Because
one QML singleton failing to compile breaks the whole `qml/model` qmldir module for every file that
transitively imports any part of it, the blast radius was much wider than the six files actually
touched — `tst_ActivityLog`, `tst_Gateway`, `tst_LockManager`, `tst_DataModel_adjustOrderSyncGuard`,
and others that never reference `PartyStore` directly all failed too.

**Fixed**: `qml/helper/SettingsPath.js`'s function renamed `settingsFileNameOverride` →
`settingsLocationOverride`, same logic (verified again via `node`), all six store call sites changed
from `fileName: SettingsPath.settingsFileNameOverride(...)` to `location:
SettingsPath.settingsLocationOverride(...)`. `SKILLS.md` Skill 41 rewritten with an explicit
correction section (not silently edited as if the mistake never happened); `AGENTS.md`'s two
references corrected. Full details: SKILLS Skill 41.

**Verification status, stated plainly**: still not run against a real `qmltestrunner` from this
sandbox (no toolchain here either) — the property-name fix is checked against Qt's own current
documentation (`qml-qtcore-settings.html`, confirmed `location: url` is the only location-control
property Qt Qml Core's Settings exposes) rather than against a compile. This needs a real
`qmltestrunner` pass to confirm before treating it as closed — same open item as before, just a
better-grounded fix this time.

## Next step

1. Push this fix immediately — CI is currently broken on this branch.
2. Taher: re-run `qmltestrunner -input tests` (or CI) to confirm the 14 failures are actually
   resolved, not just plausible-looking.
3. E2E test failures (`test/e2e/`) mentioned alongside the QML failures — not yet looked at, no
   log supplied for those yet.
4. Still open: `OrdersStore` full-coverage test work, Phase 2 probe results from Taher.

## New session (2026-08-18, later) — resumed on this branch, second QML Tests failure found and fixed

**Setup**: cloned fresh (per standing workflow), token stripped from `origin` immediately after
clone. Taher asked to check out this branch and fix a QML test failure from "attached logs" — no
file was actually attached to that message; proceeded by pulling live status from the GitHub API
instead of asking first, since it was directly checkable.

**Two things flagged to Taher up front, not silently worked around:**
- He described this as "the public repo." It isn't anymore — the clone required the PAT
  (memory already had this: made private mid-2026). Not a problem, just noting the mismatch
  between what was said and what's actually configured.
- The PAT was pasted directly into the chat message this time, not just supplied for in-URL use.
  That's a step beyond the established discipline (token used only in the push URL, stripped
  immediately after) — the token is now sitting in this conversation's history regardless of how
  carefully it's handled from here. Taher already said he'll rotate it after merge; flagging this
  now rather than after the fact.

**Status found on arrival**: commit `4d8c5aa` (the `location`-not-`fileName` fix, previous entry
above) was already committed and pushed, PR #44 open. Checked the real CI result via the Actions
API rather than assuming the fix had landed clean: **QML Tests still failing** on `4d8c5aa` itself
(`Functions Tests` / `Firestore Rules Tests` green, `E2E Tests` cancelled — see below). Tried to
pull the actual failure text two ways — the job's raw log endpoint and the `qml-test-results`
artifact — both redirect to `productionresultssa*.blob.core.windows.net`, outside this sandbox's
egress allowlist (same wall hit and documented earlier in this file, for the PR #44 E2E job). The
Checks API's own annotations for this run were generic (`"Failed test were found..."`, `"Process
completed with exit code 7"`) — no per-test detail. So: no log to read, same as last time; had to
find the failure by direct investigation instead of by asking for a log this session doesn't have
either.

**Root cause, found by comparison against `4d8c5aa`'s own diff, not by guessing**: that commit's
message says it changed "all six store call sites" and it did — but it didn't touch
`tests/tst_SettingsPath.qml`, the one file that unit-tests `SettingsPath.js`'s exported function
directly. A repo-wide grep for the pre-rename name confirmed it: all four of that file's test
functions still called `SettingsPath.settingsFileNameOverride(...)`, which stopped existing the
moment the function was renamed to `settingsLocationOverride`. Confirmed deterministically with the
same `node`-vm harness used throughout this branch: calling the old name against the current module
throws `TypeError: ... is not a function` — not a hypothesis, a reproduced fact, independent of
whatever else might also be in that CI log.

**Fixed**: renamed the six call sites in `tests/tst_SettingsPath.qml` to `settingsLocationOverride`,
no other change to that file. Re-verified all four of its assertions against the real
`settingsLocationOverride` logic in `node` — all pass. Repo-wide grep confirms zero remaining
references to the old name anywhere in `.qml`/`.js`/`.md` except `CHECKPOINT.md`'s own dated
history entries above, left untouched on purpose (this file doesn't rewrite what was believed at
the time). Added a correction addendum to `SKILLS.md` Skill 41 (same "don't silently edit the
mistake away" convention the rest of this file already follows).

**Diligence beyond the one confirmed bug**: cross-checked every store-member reference in the three
newest test files (`tst_PartyStore.qml`, `tst_CategoryStore.qml`, `tst_OrderChannelStore.qml`)
against each store's actual exposed functions/properties — all match. No further mechanical
mismatches found by this method. **Stated plainly**: this doesn't prove QML Tests will go fully
green on the next run. It proves one guaranteed, reproduced break is now fixed, and that a
reasonable static sweep didn't turn up a second one. Without the actual log or a real
`qmltestrunner` pass, "still not run against a real toolchain" stays true here too — same open
status as everything else in this file.

**Noticed mid-session, not caused by anything done here**: while investigating, the Actions API
started reporting `4d8c5aa`'s workflow run as `run_attempt: 2`, `status: in_progress` — someone
(presumably Taher, working in parallel) re-ran the failed jobs. That re-run is against the
*original* `4d8c5aa` tree (before this session's fix), so it's expected to hit the exact same
`tst_SettingsPath.qml` break again. Not waited on before pushing this fix, since the next real
signal comes from CI running *this* commit, not from watching a re-run of the old one.

## New session (2026-08-18, continued) — three more QML Tests failures, one newly discovered test-isolation bug

Resumed on `docs/e2e-testing-phase1-followup` per Taher's instruction. Cloned fresh into a new
sandbox; the clone succeeded over plain `https://github.com/...` with **no PAT needed**. Flagging
this because the entry above states this repo is private and required a PAT — that's now
inconsistent with what actually happened this session. Not resolving which is currently true;
noting the discrepancy rather than silently picking one (raised with Taher directly, not buried
here).

Taher supplied `results.xml` — a real `qmltestrunner` JUnit report, 470 tests, 7 failures — instead
of the Actions API this sandbox still can't reach either way. All four findings below come from
direct inspection of that log plus the actual source/test files at this branch's HEAD, not from
assumption. No Qt toolchain in this sandbox (standing note, unchanged) — nothing here was run
against a real `qmltestrunner`.

**Failures 1–4 — `SettingsPath` (`settingsFileNameOverride` is not a function`)**: STALE, not a
current bug. `grep -rn "settingsFileNameOverride"` across the whole repo at HEAD (`a2f60a4`)
returns zero hits — only `settingsLocationOverride` exists anywhere, consistently across source and
tests. `a2f60a4`, this branch's own last commit before this session started, is exactly the commit
that renamed the four call sites away from the old name. The uploaded log must be from a run against
an earlier commit (most likely `4d8c5aa`, immediately prior) — matching the exact scenario the
entry above already predicted ("someone re-ran the failed jobs... against the *original* tree").
**No code change made.** Recommend: re-run CI on current HEAD before treating this as open.

**Failure 5 — `CategoryStore::test_removeCategory_reassigns_default_when_removing_the_default`** and
**Failure 6 — `OrderChannelStore::test_removeChannel_reassigns_default_when_removing_the_default`**:
test-authoring bugs, not source bugs. Traced both by hand against the actual `removeCategory` /
`removeChannel` implementations — unchanged since `3d22b87` / `cad0362` respectively, both predating
this branch entirely. Both reassign the default to `arr[0]`, the first remaining item overall;
`OrderChannelStore`'s version even carries an explicit comment stating this is intentional ("first
remaining channel"). The tests (written last session in the comprehensive-coverage commit `38be363`,
never run against real Qt) assumed a different, "adjacency-preserving" fallback and asserted the
wrong constant. **Fixed**: both now compare against `.defaults[0]`, matching this file's own
existing convention elsewhere. Mechanical constant correction, not a behavior change.

**Failure 7 — `Gateway::test_drainNow_does_not_leave_an_item_stuck_in_flight_when_unauthenticated`**:
real bug, and the interesting one — a second-order consequence of the QSettings shared-file fix
from earlier this branch (`30f8ba3`/`f5d57ab`). Traced end to end:

1. `SettingsPath.js` intentionally routes *every* store's `Settings` block to the same on-disk file
   under `qmltestrunner` (mirrors production, where they already share one file, differentiated only
   by `category`). Correct and deliberate — it's what makes persistence testable at all.
2. `tst_AuthStore.qml`'s persistence test deliberately writes a real `idToken: "tok-1"` to that
   shared file, to prove persistence round-trips. It's the only test in the suite that legitimately
   does this.
3. That file's `init()` resets state before each of its OWN tests, but nothing reset state after the
   LAST one. Combined with the already-documented "QtQuickTest doesn't preserve declared function
   order" gap, whichever test happens to run last in that file isn't guaranteed to be a clean one.
4. `AuthService` is referenced by real code in exactly three files; the only one of those three that
   sorts alphabetically before `tst_Gateway.qml` is `tst_AuthStore.qml` itself — and its own
   references there are comments, not code. That makes `tst_Gateway.qml`'s own `Gateway.drainNow()`
   call the first real construction point for `AuthService` in the whole suite, assuming alphabetical
   file processing (Qt's typical default for `-input <dir>`, not independently verified here).
5. `AuthService.Component.onCompleted → init() → AuthStore.loadSession()` fires exactly once, at
   that construction point, and reads straight from the shared file. If `tst_AuthStore.qml` left
   `"tok-1"` there, `loadSession()` silently overwrites `tst_Gateway.qml`'s own
   `AuthStore.idToken = ""` (set moments earlier by that test's own `init()`).
6. That flips `_send()`'s no-auth guard open. `_send` proceeds down the real-XHR path, marks the
   item in-flight, and — synchronous test body — nothing clears it before the test's own second
   `drainNow()` call checks `dueItems()`. Result: `dueItems().length === 0`, not `1`. Matches the
   log exactly.

`tst_Gateway.qml`'s own header comment already states the assumption that broke ("don't set
`AuthStore.idToken` in these tests, or that safety property no longer holds") — written before the
QSettings fix made disk-backed contamination possible, so it correctly guarded the in-memory path
and had no way to anticipate the disk path.

**Fixed, two layers**:
- **Root fix**: added `cleanupTestCase()` to `tst_AuthStore.qml`, clearing and re-saving a blank
  session after that file's tests finish, regardless of which one runs last. New pattern in this
  suite — no prior `cleanupTestCase()` exists anywhere else. Principle: the test that writes shared
  state cleans up after itself.
- **Defense in depth**: `tst_Gateway.qml`'s `init()` now also clears `AuthStore._settings.sessionJson`
  directly, not just the in-memory `idToken`. Belt-and-suspenders on top of the root fix, not a
  substitute for it. This was my call, not Taher's — cheap and consistent with this file's already-
  defensive posture, but it's a second thing to maintain going forward, and he may reasonably prefer
  just the one root fix. Flagged to him directly, not decided silently.

**Not independently verified against a real toolchain** — same standing caveat as every entry in
this file. The Gateway fix specifically rests on an assumption about Qt's file-enumeration order for
`-input <dir>` that this sandbox cannot check.

## Next step

1. Get a real `qmltestrunner` pass from Taher's machine — this round's fixes, especially the Gateway
   one, need that confirmation more than prior rounds did.
2. Resolve the repo-visibility discrepancy (public today vs. "private, needs PAT" per the entry
   above) — ask Taher directly rather than assume either is stale.
3. Get Taher's call on whether the Gateway `init()` defense-in-depth layer should stay, or whether
   the `tst_AuthStore.qml` root fix alone is preferred.
4. `E2E Tests` on this branch still not looked at this session — separate from all of the above.
5. Still open, unrelated: `OrdersStore` full-coverage test work, Phase 2 probe results from Taher.

## Taher confirmed all tests pass (2026-08-18, continued) — independently re-verified, PR/branch landscape reviewed

Didn't just take "all tests passed" at face value — pulled the real GitHub Checks API for this
branch's HEAD (`0d4c033`) rather than relying on Taher's report alone: `QML Tests`, `Functions
Tests`, `Firestore Rules Tests`, `E2E Tests` all `completed` / `success`. Confirms this round's three
fixes (SettingsPath: no-op confirmed stale; CategoryStore/OrderChannelStore: constant fix; Gateway:
the disk-contamination fix) all hold under a real toolchain, not just the static trace.

Also pulled the full open-PR list (`api.github.com`, not assumed from memory) to answer Taher's
"where do things stand" question honestly rather than from a compressed summary:

- **PR #44** (`docs/e2e-testing-phase1-followup` → `main`) — this branch. Open, all four checks
  green as of `0d4c033`. Ready for Taher's review/merge call.
- **PR #39** (`feature/desktop-ux-design` → `main`) — open, separate parked thread (Plan 1 verified
  and done; Plan 2 tasks 1–2 done, 3–5 not started). Untouched this session.
- **PR #29** (`docs/offline-handling-design-update` → `main`) — open, last updated **2026-07-11**
  (over five weeks before today), empty PR body. No context on this in memory or anywhere in this
  file's history. Surfacing as a genuine open question, not silently ignoring it: worth confirming
  with Taher whether it's still live work or should be closed.

## Next step (current, priority order)

1. **PR #44 merge decision** — all CI green, independently confirmed. Taher's call on whether to
   merge now (small, coherent, reduces rebase risk as `main` moves) or hold to bundle in
   `OrdersStore` coverage / the Phase 2 probe result first.
2. **Two small open decisions from this round**, non-blocking but unresolved: repo-visibility
   discrepancy (informational, needs Taher to check on GitHub's side); Gateway `init()`
   defense-in-depth layer — keep both layers or drop to the `tst_AuthStore.qml` root fix alone.
3. **`OrdersStore` full-coverage tests** — the one store from the 4-store QSettings extension
   (2026-08-17) that never got matching persistence-regression coverage. Independent of the probe;
   can proceed without waiting on Taher.
4. **Phase 2 probe** — drafted since 2026-08-17, never run. The one item in the whole locked
   sequence that fundamentally can't be closed from this sandbox; needs Taher to run it locally and
   report the `=== PROBE OUTPUT ===` content. Can run in parallel with item 3, no ordering dependency.
5. **Optional, raised but not yet decided**: sweep the rest of `tests/*.qml` for other files that
   lazily reference `AuthService`/`Gateway.drainNow()` and could hit the same class of shared-disk
   contamination found this session — not yet done, not yet requested by Taher.
6. **PR #29** — needs a keep-or-close decision from Taher; not investigated further this session.
7. Unrelated, separate thread: `feature/desktop-ux-design` Plan 2 Tasks 3–5 (OrdersDetailPane,
   OrdersMasterDetail composition, `Main.qml` wiring) still pending whenever that thread resumes.

## PR #44 merged; decisions resolved (2026-08-18, continued)

Verified via API, not just Taher's word: PR #44 merged into `main` at `bc0a8fb` on 2026-08-18. Pulled
`main`, opened a fresh branch (`docs/e2e-testing-phase2-followup`) for this round, per the standing
"never commit directly to main" rule — applies even to a docs-only checkpoint update.

Taher's decisions on the open items from last round:

- **Repo visibility**: confirmed public, no PAT needed. Resolves the discrepancy flagged earlier.
  Old "private, needs PAT" entry above is left as-is (this file doesn't rewrite what was believed at
  the time) — this note is the correction.
- **Gateway `init()` defense-in-depth layer**: keep it. Taher's standing instruction: always take the
  correct/robust fix over a shortcut, project-wide, not case-by-case. Applied here — both layers
  stay (root fix in `tst_AuthStore.qml` + defensive reset in `tst_Gateway.qml`). No code change
  needed, this was already shipped in `0d4c033`; just documenting the resolved call.
- **`OrdersStore` full coverage**: confirmed go — and generalized. Taher's standing instruction now:
  aim for 100% relevant test coverage on anything Claude writes or touches, not just the specific
  gap being closed. Recorded as a durable principle (memory), not just a one-off for this store.
- **PR #29 / `feature/desktop-ux-design`**: Taher does not want Claude proactively checking or
  managing other branches/PRs — his call to make, only on request. Recorded as a durable preference
  (memory). Not investigated further.
- **AuthService-contamination sweep**: not yet decided — Taher asked for a clearer re-explanation of
  the underlying problem before deciding. Given in chat this round, not yet re-recorded here pending
  his actual decision.
- **Local test command**: Taher asked for a copy-pasteable command to run the QML test suite
  locally. Pulled the exact CI invocation from `checks.yml`'s `qml-tests` job (`qmltestrunner -input
  tests -platform offscreen -o results.xml,junitxml`) rather than reconstruct from memory, and added
  `-o -,txt` for local human-readable stdout — CI's `qml-tests` job is still missing that flag
  (confirmed still true, listed in the original deferred-gap list), `e2e-tests` job already has it.
  Given verbatim in chat.

## AuthService sweep folded into OrdersStore work; CI flag shipped; spec written and decided; Slice 1 plan written (2026-08-20)

Taher's answers this round, in order:

- **CI flag**: `qml-tests` job in `checks.yml` now has `-o -,txt` too, matching `e2e-tests`.
  Verified via `e2e-tests`' own check-run history that the flag pattern runs clean before applying
  it here (not assumed safe). Confirmed working: Taher's own CI logs from this run
  (`1_QML_Tests.txt`) show per-test `PASS` lines, 470/470, matching `results.xml`.
- **AuthService sweep** (folded into this pass, not a separate effort, per Taher): swept every file
  that actually calls `Gateway.drainNow`/`recordMutation` (the real trigger points) —
  `tst_DataModel_adjustOrderSyncGuard.qml`, `tst_Gateway.qml` (already fixed), `tst_OrdersStore_applyAdjustment.qml`,
  `tst_OutboxStore.qml`. The last one confirmed safe **by verifying no actual call exists**, not by
  trusting its header comment. The other two had the same incomplete in-memory-only defense the
  original `tst_Gateway.qml` had — extended both with the disk-level reset.
- **Full audit of `OrdersStore.qml`** (764 lines, 29 functions, re-read in full — not from memory):
  25 of 29 functions had zero direct coverage. Classified every one into "pure/local ->
  `qmltestrunner`" (22) or "Firebase-touching -> smoke-test at qml layer, real coverage at
  E2E/emulator layer" (7) — Taher's explicit instruction was not to skip the Firebase-touching
  ones, just route them correctly.
- **Spec written**: `docs/superpowers/specs/2026-08-20-ordersstore-full-coverage-design.md`.
  Surfaced three adjacent findings so nothing gets duplicated: `orderMath.js`/`OrderMath.js` is a
  *distinct* module from `computeOrderTotals` (parity-related, not the same code — **deferred,
  tracked here as pending, not dropped**, per Taher's explicit "document it as pending"
  instruction); tenant isolation for `orders` already covered generically via
  `firestore.rules.test.js`'s `WORKING_COLLECTIONS` loop; "own orders" RBAC filtering lives in
  `StaffScope`, already tested separately.
- **Taher's decisions on the spec's 3 open questions**: (1) `orderMath.js` parity — deferred,
  documented as pending, not folded into this pass. (2) E2E tests — **separate new file**
  (`test/e2e/tst_OrdersStoreE2E.qml`, not an extension of the existing `tst_OrdersE2E.qml` — this
  overrides my own proposed default in the spec). (3) No exceptions on coverage — every Group A
  function gets tests, including the two trivial one-line getters.
- **Plan-writing scope decision**: the `writing-plans` skill's own guidance ("if the spec covers
  multiple independent subsystems... break into separate plans, one per subsystem") plus that same
  skill's "no placeholders, complete code every step" requirement made one mega-plan covering all
  5 files impractical and against house guidance. Splitting into 5 separate plan docs, one per
  file from the spec's §6 layout, written and reviewed incrementally rather than all at once.
- **Slice 1 plan written and verified**: `docs/superpowers/plans/2026-08-20-ordersstore-totals-coverage.md`
  — `tst_OrdersStore_totals.qml` (`computeOrderTotals`, `parseCurrency`, `formatCurrency`), 26 test
  functions across 3 tasks/commits. Every expected value in that plan was verified by porting the
  actual functions to Node.js and executing them (`node --version` confirmed available in this
  sandbox), not hand-calculated — including a genuine, proven rounding-order divergence case
  (step-wise gives `9.99`; a naive single-final-round would give `10.00`) rather than an assumed
  one that turned out not to actually diverge on the first attempt (first constructed case didn't
  diverge; caught by verifying, not by assuming the math was right).

## Slices 2–5 written, all five OrdersStore coverage plans complete (2026-08-20, continued)

All four remaining plans written in one pass, same standard as Slice 1 (verified where verification
was possible, gaps found via self-review fixed inline rather than left silent):

- **Slice 2** (`docs/superpowers/plans/2026-08-20-ordersstore-queries-coverage.md`) —
  `tst_OrdersStore_queries.qml`: `get`/`getById`/`findIndexById`/`openOrdersForProduct`/
  `pendingCount`/`completedThisMonth`/`totalRevenue`/`processingCount`. 26 tests, 3 tasks. No
  floating-point involved, so verified by direct source trace rather than Node — said so explicitly
  rather than implying the same machine-verified confidence as Slice 1.
- **Slice 3** (`docs/superpowers/plans/2026-08-20-ordersstore-mutations-coverage.md`) —
  `tst_OrdersStore_mutations.qml`: the largest slice. `clear`/`_refreshCounts`/`_commit`/
  `_mergeOrder`/`nextOrderId`(smoke)/`upsertMany`(its empty-input path turned out to be fully
  synchronous — real coverage, not just smoke)/`updateOrder`/`deleteOrder`/`_normalizeOrder`/
  `_normalizeOrders`. 35 tests, 5 tasks + 1 addendum. Traced two genuinely non-obvious real
  behaviors while writing this one: `updateOrder`'s local state is normalized once via `_clone()`
  before field mutations, not re-normalized by the second `_normalizeOrder(o)` call `_commit`
  builds for the Gateway payload; `deleteOrder` bumps `revision` unconditionally even on a no-op
  delete for an unknown orderId, only the actual `Gateway.recordMutation` call is guarded. Both
  tested as real, traced behavior rather than assumed or routed around. Self-review caught a real
  gap — `addOrder`'s own smoke test was in the spec's file layout but no task had actually added it
  — fixed via an addendum task in the same document rather than silently left out.
- **Slice 4** (`docs/superpowers/plans/2026-08-20-ordersstore-sync-coverage.md`) —
  `tst_OrdersStore_sync.qml`: `_onMutationConflicted` (full coverage, including the same
  unconditional-revision-bump pattern found in Slice 3, this time for the conflict-with-nothing-
  locally-known edge case) plus `_load`/`_resetAndFetch`/`_fetchFromFirebase`/`syncFromFirebase` —
  upgraded from pure smoke tests to real re-entrancy-guard coverage (both `_resetAndFetch` and
  `_fetchFromFirebase` have their own independent `loadingMore` guards, tested separately since
  they're separate lines even though they check the same flag), matching the
  `TransactionStore_resetGuard` precedent already established elsewhere in this suite. 12 tests, 2
  tasks.
- **Slice 5** (`docs/superpowers/plans/2026-08-20-ordersstore-e2e-coverage.md`) — new file,
  `test/e2e/tst_OrdersStoreE2E.qml`, per Taher's decision to keep it separate from the existing
  `tst_OrdersE2E.qml`. Real emulator coverage for `addOrder`, concurrent `addOrder` (no id
  collision — the actual reason `mintCounterValue` exists, first test anywhere in this codebase
  that exercises real request concurrency rather than trusting the source comment's stated intent),
  `upsertMany`'s three conflict policies, `syncFromFirebase` pagination (55 seeded orders, past
  `_pageSize`'s 50), and — the standout scenario — a genuine multi-user conflict using two real
  identities. That last one required extending `test/e2e/seed.js` with a second seeded user
  (`e2e-staff`) and a second minted token (`fixture.secondIdToken`) — additive only, existing E2E
  files unaffected, but flagged as touching shared infrastructure, not just adding a new file. 6
  tasks (including one self-review-caught addendum for pagination, same pattern as Slice 3).
  Explicitly flagged as this whole plan series' least certain test: the raw-POST-from-a-second-
  identity mechanic for forcing a real CAS conflict couldn't be executed to confirm in this
  sandbox, said so directly in that task rather than presented with false confidence.

**Total across all 5 slices: 122 new test cases, 5 new/modified files (4 new `tests/*.qml`, 1 new
`test/e2e/*.qml`, plus the `seed.js` extension), none implemented yet — plans only, awaiting
Taher's review before any of the actual test code gets written to the real files and committed.**

## Next step

1. Taher reviews the 5 plans (or picks a subset to start with) — nothing implemented from them yet,
   per the standing spec→plan→approval→code process.
2. Once approved: implement in the spec's §8 rollout order — Slices 1→2→3→4 (Group A, no emulator
   dependency, fastest feedback) before Slice 5 (E2E, and specifically needs `computeOrderTotals`'s
   exact behavior settled first since several E2E assertions reuse those verified values).
3. `orderMath.js`/`qml/helper/OrderMath.js` parity — tracked here as deferred/pending, not
   forgotten. No action until Taher decides to pick it up.
4. Phase 2 probe (`scripts/probes/probe_dp_sp_outside_app_root.qml`) — still needs Taher to run it
   locally and report the `=== PROBE OUTPUT ===` content. Independent of everything above, can
   happen in parallel any time.

## All 5 slices implemented (2026-08-20, continued)

Taher said to proceed straight to implementation rather than pausing for a separate plan-review
round. Implemented all 5 slices exactly as planned, one commit per task, same order as each plan
document:

- Slice 1 (`tests/tst_OrdersStore_totals.qml`) — 3 commits, 26 tests.
- Slice 2 (`tests/tst_OrdersStore_queries.qml`) — 3 commits, 26 tests.
- Slice 3 (`tests/tst_OrdersStore_mutations.qml`) — 5 commits (Task 5 and its addendum combined
  into one commit rather than kept as two, the only deviation from a plan's exact commit-count —
  noted here since precision matters, even for something this small), 35 tests.
- Slice 4 (`tests/tst_OrdersStore_sync.qml`) — 2 commits, 12 tests.
- Slice 5 (`test/e2e/seed.js` extension + new `test/e2e/tst_OrdersStoreE2E.qml`) — 6 commits, 6
  test functions covering `addOrder`, concurrent `addOrder`, `upsertMany`'s three conflict
  policies, the multi-user conflict, and pagination.

**122 test cases total, all written and pushed to `docs/e2e-testing-phase2-followup`.** Correction
made after implementing (this estimate was written before the code existed): actual grep count
across the 5 files is **106** (26+26+36+12+6), not 122 — the plan docs' own per-task test counts
undercounted Slice 3's `_mergeOrder`/`nextOrderId`/`upsertMany` task by one (said 7, actually 8).
Verified by `grep -c "function test_"` against the real files rather than trusting the planning
estimate, same discipline as everything else in this project. **None run against a real Qt
toolchain or Firebase emulator** — every new file says so in its own header, same standing
limitation as everything else in this project. This is the single biggest thing this branch needs
before it can be considered done: a real `qmltestrunner` pass for the four `tests/*.qml` files, and
a real `e2e-tests` CI run (or local `firebase emulators:exec`) for `tst_OrdersStoreE2E.qml` and the
`seed.js` change.

## Next step

1. **Get a real test run.** Local: `qmltestrunner -input tests -platform offscreen -o -,txt` for
   Slices 1–4. CI or local `firebase emulators:exec` for Slice 5 — this is the first real run for
   `tst_OrdersStoreE2E.qml` and the `seed.js` second-identity extension both.
2. Slice 5's multi-user conflict test (`test_two_users_editing_the_same_order_produces_a_real_conflict`)
   is the specific one flagged as least certain across the whole series — if anything in this batch
   fails, check that one first, and specifically check `staffWinResult.status` if it does.
3. `orderMath.js`/`qml/helper/OrderMath.js` parity — still deferred/pending, unchanged from before.
4. Phase 2 probe — still needs Taher to run it locally, unchanged from before, independent of
   everything else.

## First real run: 9 QML + 2 E2E failures, all root-caused and fixed (2026-08-21)

Taher ran the implementation for real and reported back genuine failures — the first actual
`qmltestrunner`/`e2e-tests` execution any of Slices 1–5's code has ever had. Root-caused every one
before touching anything (read error messages precisely, read the actual current source, didn't
guess), per `systematic-debugging`. Summary:

**QML (9 failures, all fixed):**

1. **5× `Toast is not defined`, all `OrdersStore_sync::test_onMutationConflicted_*`.** Root cause:
   `_onMutationConflicted` calls `Toast.show(...)` unqualified — normal for `qml/model/*.qml` code,
   works in the real app because `Main.qml` does `import "components"`. `Toast` is a
   `qmldir`-registered singleton in `qml/components/`, a *separate* module from `qml/model` (which
   is all `tst_OrdersStore_sync.qml` imported). First test in this whole suite to ever exercise a
   code path that calls `Toast.show()` — nothing before this hit the gap. Fix: added
   `import "../qml/components"`, matching `Main.qml`'s own precedent exactly. Confirmed
   `Toast.qml` itself is a 4-line inert `QtObject` (just emits a signal, no host dependency), so the
   import alone is sufficient.
2. **2× `Compared values are not the same`, both genuine test-authoring bugs:**
   - `test_normalizeOrder_resolves_tax_from_inventory...`: fixture used `InventoryStore.products`
     field `id`, but `InventoryStore.getById()` matches on `productId`
     (`qml/model/InventoryStore.qml:1051`). Fixed both occurrences of the wrong field name in this
     file (one failed, one coincidentally passed anyway since it overrides tax on the line itself
     regardless — fixed for correctness, not just to stop a visible failure).
   - `test_updateOrder_uses_fields_total_directly...`: seeded an empty `products: []` array with a
     hand-set `subtotal: 50`. Real behavior: `_clone()` unconditionally recomputes
     `subtotal`/`discount`/`tax` from `products` via `_normalizeOrder` on *every* `updateOrder`
     call — no fallback-to-existing branch for `subtotal` the way there is for `items`/`total`
     (`qml/model/OrdersStore.qml:394` vs `:393,:398`). An empty-products seed gets its subtotal
     zeroed by the clone before `fields.total` is ever applied. Fixed by seeding a real product line
     that computes to `subtotal: 50`, making the original intent ("subtotal stays put, only total is
     overridden") actually true.
3. **2× `formatCurrency` — confirmed, not just theorized.** This environment's QJSEngine throws on
   `Intl.NumberFormat`; the manual fallback fires (`'INR ' + rounded`, no comma grouping). Exactly
   the open question flagged as unverified when this test was first written. Fixed both to check
   digit content only. The other three `formatCurrency` tests already didn't assume comma grouping,
   which is why they passed.

**E2E (2 failures, both fixed):**

4. **`test_upsertMany_skip_and_rename_policies_against_real_state`** — `"recordMutationsBatch
   failed 401 ... invalid-token"`. Root cause: `Gateway.batchFunctionUrl` defaults to the *real*
   production Cloud Function URL (`qml/model/Gateway.qml:53`) — `init()`/`cleanup()` redirected
   `functionUrl` and `deltaFunctionUrl` to the emulator but missed `batchFunctionUrl` entirely.
   `upsertMany`'s real-records path was hitting prod, which correctly rejected the fake
   emulator-signed token. Fixed by adding the same redirect pattern for the third URL.
   `test_upsertMany_overwrite_policy_...` had the identical latent bug but happened to pass — its
   assertion depends on a separate `updateOrder` call using the already-correct `functionUrl`, not
   on `upsertMany`'s own network write.
5. **`test_two_users_editing_the_same_order_produces_a_real_conflict`** — the one flagged from the
   start as least certain. Two real, distinct bugs, both found by reading the actual code rather
   than re-guessing:
   - `E2EHelpers.postDirect` hardcodes `tc.fixture.idToken` — no parameter for a different token at
     all. The "staff write" was silently using the owner's own identity the whole time.
   - More fundamental: `functions/lib/gatewayLogic.js`'s `applyMutation` does
     `_deepEqual(current, params.before)`, where `current` is Admin-SDK-read plain JS values
     (`{customer: "x"}`) — but this test built `before`/`after` from `orderDoc.fields`, Firestore's
     REST typed-value wire format (`{customer: {stringValue: "x"}}`). Those shapes can never
     deep-equal; the CAS check would reject the write regardless of identity.
   Fixed with two new local helpers in the test file: `_postDirectAs(idToken, ...)` (explicit-token
   variant, kept local rather than modifying the shared `E2EHelpers.js`, same convention as
   `_addOrder`) and `_firestoreFieldsToPlain(fields)` (a converter scoped to the value types
   OrdersStore documents actually use, not a general-purpose Firestore parser). Also added a
   `compare()` on the staff write's status that wasn't there before, so a rejected write fails
   loudly where it happens instead of as a confusing timeout several lines later.

**Not re-verified against a live run** — same standing sandbox limitation as every fix in this
project. All of the above is root-caused from the actual failure logs and actual current source,
not guessed, but Taher needs to re-run before this is confirmed closed.

## Next step

1. Re-run both `qmltestrunner` (Slices 1–4) and `e2e-tests`/local emulator (Slice 5) — first real
   confirmation these fixes hold.
2. If anything still fails: paste the log back, same as this round — don't re-guess blind.
3. `orderMath.js`/`qml/helper/OrderMath.js` parity — still deferred/pending, unchanged.
4. Phase 2 probe — still needs Taher to run it locally, unchanged, independent of everything else.

## Second run: down to 5 QML + 1 E2E, both root-caused differently than first guessed (2026-08-22)

**QML — last round's Toast fix was wrong, still 5 failing, same error.** Corrected mental model: a
QML file resolves unqualified type references (`Toast.show(...)` inside `OrdersStore.qml`) based
on *that file's own* imports, not the caller's. My test file importing `qml/components` did nothing
for `OrdersStore.qml` itself. Production works via `qt_add_qml_module` bundling `qml/model` +
`qml/components` into one cohesive module (sibling types visible without explicit imports) — a
build-system behavior bare `qmltestrunner -input tests` doesn't replicate. Real fix: explicit
`import "../components"` added to all four `qml/model/*.qml` files that call `Toast.show()`
(`InventoryStore`, `OrdersStore`, `StaffStore`, `SupplierStore` — checked all four for consistency,
not just the one under test). Safe, additive, zero behavior change in the compiled app. Removed the
ineffective test-file import so it doesn't mislead later.

**E2E — down to 1 failure, root-caused as likely OutboxStore cross-test contamination.** The
conflict test's `Gateway.mutationConflicted` never fired; the QWARN right before it was a
transport-level failure (status 0), not a real HTTP rejection — which only happens if the owner's
update never reached the server at all. Traced: `tst_OrdersStoreE2E.qml` never called
`OutboxStore.clear()` anywhere, the one gap in the whole suite. `OutboxStore` is shared across the
entire `test/e2e` process; `stock_batch BAT-2026-001` (also seen as noise during unrelated tests in
this file) traces to `tst_OrdersE2E.qml::test_completeOrder_rejects_when_stock_insufficient`'s own
deliberate negative-path failure, left queued and retried by every subsequent `recordMutation` call
system-wide. Confirmed the other two E2E files don't need the same fix (they bypass Gateway/
OutboxStore via raw POSTs for everything except `completeOrder`, which is the actual origin, not a
second gap). Fixed by adding `OutboxStore.clear()` to this file's `init()`.

**Honest caveat, stated directly rather than overclaimed**: the OutboxStore fix is real, confirmed,
and well-evidenced, but a transport-level status-0 failure can also stem from genuine transient
emulator load under CI, independent of this contention. Can't rule that out from static analysis
alone.

## Next step

1. Re-run again. If the E2E conflict test still fails with the same status-0 pattern after this
   fix, that would point toward genuine emulator flakiness rather than the contention theory —
   worth knowing either way.
2. `orderMath.js`/`qml/helper/OrderMath.js` parity — still deferred/pending, unchanged.
3. Phase 2 probe — still needs Taher to run it locally, unchanged, independent of everything else.

## Third run: QML fully green, E2E down to the same one test — real root cause found (2026-08-22)

QML: 100% pass, confirmed — the Toast fix (import in the 4 source files, not the test file) holds.

E2E: same single failure, same "order ORD-061 recordMutation failed 0" pattern as last round —
meaning the OutboxStore.clear() fix, while a real and worthwhile hygiene fix, wasn't the actual
cause of *this* symptom. Went back to the source instead of re-guessing: read
`qml/model/OutboxStore.qml`'s actual `_backoffMs` array — `[2000, 8000, 30000, 120000, 600000]`.
The ~2.15s gap between this run's two logged failures matches `backoffMs[0]` (2000ms) exactly, not
a coincidence — confirms the retry mechanism is working correctly, the test's 10s `tryVerify` window
just didn't give it enough time (a 3rd attempt needs 2000+8000=10000ms from the first failure,
landing right at the old timeout's edge). Verified `Gateway.drainNow()` self-schedules via its own
`_drainTimer`/`_onDrainTick` — a real, self-perpetuating retry loop, nothing external needs to
trigger it. Fixed by increasing the timeout to 45s, real margin past a 4th attempt.

The first-attempt transport failure itself is most likely genuine emulator contention from the
concurrent-addOrder test's own counter-mint retry storm (visible in this same log as a 400
FAILED_PRECONDITION version-mismatch on that test, landing moments before) — not something to
eliminate, since tolerating real transient infrastructure behavior via the system's own designed
retry mechanism is the correct fix, not routing around it.

## Next step

1. Re-run once more. If this still fails, the 45s timeout theory would be wrong and this needs a
   different explanation — say so plainly rather than guess a fourth time.
2. `orderMath.js`/`qml/helper/OrderMath.js` parity — still deferred/pending, unchanged.
3. Phase 2 probe — still needs Taher to run it locally, unchanged, independent of everything else.

## Fourth run: same failure, new data, no confirmed root cause this time (2026-08-22)

Precise timing now visible from a fuller log read: create→poll→staff-write→poll-confirm→owner-
update-attempt all completes in ~230ms, and 4/4 retries (2.1s/8.05s/30.04s gaps, confirming the
backoff-schedule fix from last round is correct) fail instantly with status 0, empty responseText.

Ruled out this round: (1) simple transient contention — 4 identical failures across 40+ seconds
of calendar time isn't consistent with random network blips; (2) a masked server-side crash —
read `functions/index.js`'s actual `recordMutation` handler in full for the first time (had only
checked `gatewayLogic.js`'s pure logic before); it's properly try/catch-guarded around both auth
verification and `applyMutation`, would cleanly return 500 on a real exception, not fail the
connection; (3) `deriveContext` (the one unguarded call) as a differentiator — same actor/tenant's
earlier `addOrder` create call succeeds fine in the same test run, so context derivation clearly
works for this identity.

**No confirmed root cause this round** — said so directly rather than presenting a guess as a fix.
Added diagnostic logging (`Gateway.functionUrl` value right before the failing call) and a
defensive 500ms settle delay (cheap, doesn't fully explain the later retries but rules out any
rapid-fire connection-reuse concern for the first attempt). Next log should either show a wrong
`functionUrl` (a real answer) or confirm it's correct (meaning the remaining mystery is somewhere
this diagnostic can't reach, and needs a different approach — server-side function logs, most
likely, which aren't visible from the qmltestrunner-side log alone).

## Next step

1. Re-run. Check the new `[DEBUG conflict test] Gateway.functionUrl = ...` line specifically.
2. If `functionUrl` is correct and this still fails: the next real lead is probably Cloud Functions
   emulator server-side logs (not visible in `2_E2E_Tests.txt`), if Taher can capture those from a
   local `firebase emulators:exec` run.
3. `orderMath.js`/`qml/helper/OrderMath.js` parity — still deferred/pending, unchanged.
4. Phase 2 probe — still needs Taher to run it locally, unchanged, independent of everything else.
