# Test plan — delete roadmap S4 cleanup (docs only)

**Branch:** `docs/2026-10-13-delete-roadmap-s4-cleanup` off `main` @ 0716427. **Design:** none needed (docs only; scope in `DELETE-FEATURE-ROADMAP.md`, last paragraphs).
**Covers:** `DELETE-FEATURE-ROADMAP.md` (marked complete), five `KNOWN-ISSUES.md` headings/status lines (item 1 black hole, destroy-before-ack, PH3 and PH3b status), the README "Still open" block of the 2026-08-06 review (5 stale items corrected), Skill 116, regenerated `SKILLS-INDEX.md`.
**Not covered:** the app. No QML, Functions, Rules or e2e file changed; nothing ships to a device.

## 1. Unit / functional
| Check | Command | Result (run 2026-10-13) |
|---|---|---|
| Index is current after adding Skill 116 | `node .github/scripts/skills-index.js --write` then `--check` | 117 skills, "is current", exit 0 |
| Script suite (includes the repo-state guard that fails on a stale index) | `node --test .github/scripts/__tests__/*.test.js` | 76/76 pass |

## 2. Claim verification (every claim the docs now make, with the proof)
| Claim | Command | Proof |
|---|---|---|
| FIFO uses `recordDelta`; only `create` uses `recordMutation` | `grep -n "Gateway.recordMutation(\|Gateway.recordDelta(" qml/model/StockBatchStore.qml` | `recordMutation` at 381, 400, 491 (all `"create"`); `recordDelta` at 568 (consume), 671 (restore); `topUpOldest` calls `addBatch` (a create) |
| `recordMutationsBatch` has CAS | read `functions/lib/batchMutationLogic.js` 125-131 | `_deepEqual(current, item.before)` mismatch collects conflicts, returns `{ok:false, status:409, conflicts}` |
| Bulk approve locks each order | `grep -n "LockManager.acquire" qml/pages/OrdersPage.qml` | line 507 in `_approveAllPending` |
| `ConfirmReturnSheet` owns the lock | `grep -n "onClosed: LockManager.release" qml/pages/ConfirmReturnSheet.qml` and `_lockHandoffPending = false` in `OrderDetailDialog.qml` | ConfirmReturnSheet 95; OrderDetailDialog 333 |
| Partial multi-line failure is compensated | read `DataModel._finishAdjustment` (1119) and `_restoreFifoSafe` (64) | failed sibling restores consumed batches (1132); completion is one atomic operation (PR #90) |
| KNOWN-ISSUES headings match merged work | `git log --oneline origin/main` shows #93 (C), #97 (S1, S2a), #106 (S2b), #110 (S3), #118 (BC1), #119 (BC2); read `InventoryStore.deleteProduct` 1086-1120 | only the product delete is sent; Activity entry and photo purge wait in `_onMutationApplied`; a parked write refuses the delete (`hasParkedWrite`) |
| PH3b "not deployed" wording | no code proof possible | per Taher's report 2026-10-12 (DV-1..DV-9); the wording says "reported done by Taher", not "verified" |
| No stale wording left | `grep -n "still route through\|has no CAS check at all" README.md docs/superpowers/DELETE-FEATURE-ROADMAP.md` | no output |
Limit: the claims are proved by reading code, not by running the QML tests (no Qt in the sandbox; CI is the signal for the code itself, and it did not change).

## 3. E2E
None. The next CI run executes the script suite (repo-state guard).

## On-device test plan
Not applicable (docs only). Sections kept for the convention:
- **Happy path:** open `DELETE-FEATURE-ROADMAP.md`; the last paragraphs say item 1 is closed and list one open delete item (O1/O2 device re-check).
- **Negative:** pick any item the README used to list as open; the grep in section 2 shows the fix in code.
- **Edge cases:** the O1 and O2 device steps are still unticked in `2026-09-30-photos-s3-s4-s5-test-plan.md` section 9 (lines 266-267). They are Taher's.
- **Multiple scenarios:** a parallel PR that touches the roadmap tail conflicts in one paragraph; keep the newer text.
- **Monkey:** not applicable.
- **Regression watch:** a future "still open" list that names code which already changed (Skill 116).
