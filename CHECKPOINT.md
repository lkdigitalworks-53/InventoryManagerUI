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

Remaining, not yet triaged this round: QSettings org-identifier warnings under `qmltestrunner`,
`functions-tests`' exposure to the directory-sweep mechanism, and the Phase 1 spec addendum note.
Paused here — this checkpoint update and the two findings above go to Taher before continuing.
