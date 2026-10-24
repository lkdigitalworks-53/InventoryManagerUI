# PR #154 final sweep — P1 S2a-2 (delete `Gateway` direct mode + `mode`)

**Date:** 2026-10-24. **Reviewed head:** `6e68a53` (2 commits on `main` @ `d5882ee`). **Branch of this sweep:** `review/2026-10-24-pr154-final-sweep` (stacked on the PR branch; docs only, **no code changed**).
**Skills run:** `requesting-code-review` (reviewer template applied by hand, no subagent tool in this chat), `ponytail-audit` (scoped to the PR), `qt-qml-review` (Phase 1 linter run; Phase 1b `qmllint` NOT available; Phase 2 six missions done by hand on the whole of `Gateway.qml` + the 3 touched files).
**CI on head:** 2964/2964 green (QML 2104 = predicted 2107 - 4 + 1, Functions 722, Rules 45, E2E 93). No human review comments on the PR.

## Verdict
**Ready to merge: with fixes (all small, none blocks).** No bug, no security or data-loss finding in the production change. The change is what the PR says it is: 14 lines added, 91 removed in 4 production files; all 7 mode branches/guards gone; nothing outside `Gateway` + tests used the two removed error strings (grep).

## Claims I re-checked (all true)
| PR claim | Check | Result |
|---|---|---|
| 89 uses in 32 files on `main` | `git grep -c "Gateway\.mode" main -- . ':!*.md'` | 89 / 32 |
| Production +14 / -91 | `git diff --numstat` on `qml/` | +14 / -91 |
| 7 mode branches removed | 3 `=== "direct"` + 4 `!== "gateway"` lines in the diff | 7 |
| QML 2107 -> 2104 | `function test_` count `tests/` main 1885, PR 1882; `tst_Gateway` 186 -> 183 | consistent (-4 +1) |
| Only `FirebaseService` use left in Gateway is `environment` | grep | true; `put/putMany/remove` still have other callers (ActivityLog, AuthService, stores), so nothing became dead |
| `Gateway.mode` left on head | `git grep` | 2 hits: the pin test and `firestore.rules:154` (finding S3) |
| Docs index | `skills-index.js --check`, `node --test .github/scripts/__tests__` | current; 109/109 |
| Lint (qt-qml-review Phase 1) | main vs PR, 4 production files + 33 test files | 0 findings on any added line; totals only fall (623 -> 613 production, 1271 -> 1260 tests) |

## Strengths
- Surgical production diff; the per-sender `!AuthStore.idToken` guard stays the only thing keeping tests off the network, and the header comment says so.
- Honest PR body: it names its own main risk (a file that lived off the leaked `"direct"` state). My independent scan of every test file that calls a store function reaching `Gateway.record*` found no file the CHECKPOINT list missed (static scan, 66 writer functions, not a proof).
- Pin written in the `typeof` style that CI already proved on #152; mutation check documented.
- Skill 125 corrects the blast radius (79/22 -> 89/32) and the count is right.

## Findings

### Should fix
**S1. Dead branch that would write ledger rows for an edit that was never queued** (`qml/model/InventoryStore.qml:1451`)
- What: `if (parentId === "") ActivityLog.record(...) else _queueUpdateActivity(...)`. `""` used to mean "direct mode, nothing to wait for".
- Problem: now `recordEdit` returns `""` only for a bad entity or id. `updateProduct` returns early for an unknown product (`idx < 0`, line ~1418), so the id is always real and the entity is `"inventory"`: the branch cannot run. The PR's own new comment says "not reachable". If it ever did run, it would record an Activity entry and (via `parentId ""`) un-held ledger rows for an edit that is not in the outbox: the exact ledger drift this slice removes. No test reaches it (before or after).
- Fix: delete the `if` line and the `""` sentence in the comment; always `_queueUpdateActivity(...)`. (Trade-off: a defensive guard costs one line, but a guard that does the wrong thing is worse than a crash in a test.)
- If we skip it: 1 untested branch stays that violates the 100%-coverage rule.

**S2. On-device test plan is not in the format Taher asked for** (`docs/superpowers/test-plans/2026-10-23-p1-s2a2-delete-direct-mode-test-plan.md`, "On-device" section)
- Problem: paragraphs, not numbered steps with an expected outcome each (rule stated 2026-10-15 after PR #139). "Happy path" is 7 actions in one sentence ending in "All sync".
- Fix: rewrite as a table: `# | Action | Expected`, prerequisites on top, one block each for happy / negative / edge / regression / monkey. Docs only.

**S3. `firestore.rules:154-155` comment names the deleted property and is wrong about today**
- Problem: "will route through the gateway once P0 cutover flips Gateway.mode to "gateway"; until then clients write directly". The flip happened 2026-07-29 and the property is gone. The true, useful statement is: `inventory` is STILL client-writable by any member until S2c locks it.
- Fix: reword the comment (no rule change, rules tests unaffected). Trade-off: touching `firestore.rules` means a rules deploy diff for a comment; harmless, but Taher may prefer to fold it into S2c, which rewrites this block anyway. Recommend: fold into S2c.

**S4. Two files now enqueue but, unlike the 8 other enqueuing files, never blank `AuthStore.idToken`** (`tests/tst_InventoryStore_upsertMany.qml`, `tests/tst_StockBatchStore.qml`)
- Problem: `Gateway.functionUrl` defaults to the PRODUCTION Cloud Function. If any earlier-sorting file leaks a non-empty token, these two would POST to production from a unit test. Today nothing leaks: I grepped every non-empty `idToken` setter in `tests/` (`tst_AuthStore` cleans in `cleanupTestCase`, `tst_PhotoQueue` blanks in `init`/`cleanup`, `tst_ProvisionStaff...` blanks). `tst_AuthStore`'s own comment says QtQuickTest does not guarantee file order, so the safety is luck-of-ordering.
- Fix: `AuthStore.idToken = ""` (and `AuthStore._settings.sessionJson = ""`) in `init()` of both files. 2 lines each.

### Nice to have
- **N1. README contradicts itself on one line** (`README.md:344`): "S2a-2 done" and, further along the same line, "`direct` mode goes in S2a-2". Delete the second clause.
- **N2. Stale "gateway mode" / "direct mode" wording the PR missed** (Skill 125 rule 4 says to grep for it): `tests/tst_Gateway.qml:67` ("mode + collection mapping") and `:117` ("gateway-mode enqueue"); `tests/tst_InventoryStore_overlayAndCap.qml:14`; `tests/tst_InventoryStore_updateProductAfterAck.qml:11,13` ("Direct mode is not exercised"); `tests/tst_OutboxStore.qml:17`; `test/e2e/tst_InventoryE2E.qml:9`; `AGENTS.md:1012` (S3 Discard line says it checks "gateway mode").
- **N3. Gateway.qml leftovers**: 3 blank lines where `_writeDirect` was (~L377-379) and after `_finishOperation`; the new `// ── sending ──` banner is shorter than its siblings; the `discardParked` doc block (text edited by this PR) still sits above `isParkedKey` (misplaced since Task 11).
- **N4. Pin is narrow**: only `typeof Gateway.mode`; `_writeDirect` / `_writeDirectBatch` could return unpinned. Advice: do NOT add pins for deleted private helpers (test noise). Skip.
- **N5. Small count slips in the PR text**: "Tests (31 files)" but 33 test files changed (31 + the 2 cleanup-only files).
- **N6. SKILLS.md:628 "Current status (updated 2026-07-29)"** still describes `Gateway.mode` and `runCutover`, both deleted. Historical; add one "superseded by Skill 124/125" line or leave.
- **N7. Pre-existing, outside the PR** (`Gateway.qml:42-45`): `deltaFunctionUrl` comment says "NOT YET DEPLOYED ... aspirational"; `recordDelta` is exported in `functions/index.js:307` and used in production. Misleading.

### Investigation targets (confidence 60-79, human to verify)
- **I1 (65): `tst_Gateway.init()` resets `idToken` and the on-disk session but not `AuthStore.isAuthenticated`.** `drainNow()` now runs `AuthService.ensureFreshToken()` in every test of that file (it used to be skipped for the few tests that forced `"direct"`). If the singleton is still authenticated with an expiry inside 5 minutes, that calls `refreshIdToken()` = a real XHR to Google. `tst_PhotoQueue` guards exactly this with `isAuthenticated = false`. Exposure already existed: 40 tests in the file forced `"gateway"` themselves (plus every test that goes through `_queueWrite` / `_parkedWrite`), and CI is green, so likely benign. Verify: add `AuthStore.isAuthenticated = false` to `init()` (1 line) and watch CI stay at 2104.
- **I2 (62): the leak audit assumes alphabetical file order.** Skill 125 rule 2 builds the list from `sort`; `tst_AuthStore` documents that order is not guaranteed. The durable guard is each file clearing its own outbox in `cleanup()`, not the order. Verify: a one-off CI run with the files shuffled (`-input` list in a different order) is the only real proof; not worth a PR, worth a note in Skill 125.

## Not checked
- All QML (no Qt in the sandbox; CI is the oracle) and `qmllint` (not installed). Phase 1b skipped.
- On-device behaviour (Taher's list). Server side (untouched by this PR; 722 functions tests are CI's).
- `docs/superpowers/plans/*` and old specs still say `Gateway.mode`: history, left alone on purpose.

## What this PR does NOT change (so nobody reads more into it)
Firestore rules still let any member write `inventory` directly; `FirebaseService.put/remove` still exist for non-gateway collections. The real server-side bypass closes in S2c, not here.
