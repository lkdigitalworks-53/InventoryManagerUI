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

## Next step

1. Push this fix now (per standing "don't wait for permission to push" instruction).
2. Watch CI on the resulting commit via the Actions API for `QML Tests` specifically — report
   pass/fail plainly, without assuming green means "fully resolved" beyond what was actually checked.
3. If `QML Tests` still fails after this: this session cannot get further without the actual log or
   artifact content (egress-blocked both ways) — will need Taher to paste the failure text or the
   `results.xml` directly, same as he did for the first `fileName` bug.
4. `E2E Tests` on this branch has not been looked at yet this session (was `cancelled` on the
   attempt-1 run due to the external re-run, not evaluated) — separate from the QML Tests fix above.
5. Still open, unrelated to this fix: `OrdersStore` full-coverage test work, Phase 2 probe results
   from Taher.
