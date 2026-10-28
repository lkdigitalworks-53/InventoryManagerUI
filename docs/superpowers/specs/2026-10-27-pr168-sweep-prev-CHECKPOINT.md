# CHECKPOINT — 2026-10-26 S0 sign-out guard + pending-mint tenant scope (resume here)

**Branches:** PR #167 `feat/2026-10-26-signout-guard` (off `main` @ `b494d52`, #161 merged); STACKED on it: `fix/2026-10-26-pending-mints-tenant-scope`. **Commit identity:** `Taher (via Claude session) <lkdigitalworks@gmail.com>`. PAT only inline in the push command; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML oracle); push without asking; short scope; honest trade-offs; tests + test plan for every change; caveman FULL for chat only.
**Skills used:** `superpowers:brainstorming`, `qt-development-skills:qt-qml`, `qt-development-skills:qt-ui-design`, `ponytail:ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-26-pr161-merged-prev-CHECKPOINT.md`.

## Why this task
PR #161 merged; Taher deploys + device-tests it. Next important item with a ready design and no deploy: the sign-out guard (design 4b of the unmerged restock design PR #147, answered by Taher as Q-A6 = warn and allow; the restock design says it must ship before restock). Verified in code: `Main.qml onSignedOut` clears `Gateway` + `PhotoQueue`, the old confirms never mentioned queued work.
Ranked and NOT picked: L1/L2 multi-role login (DRAFT, 8 open decisions, needs Taher), S2f-3 client wording (small, later), restock-as-one-operation (needs PR #147 approval first), S2f-6 server counters (needs design).

## Steps
- [x] 1. Read memory, cloned, read CHECKPOINT + roadmap + KNOWN-ISSUES + S2f design + multi-role design + restock design.
- [x] 2. Design doc `specs/2026-10-26-signout-guard-design.md` (options A/B/C, decisions D-S0-1..7, Q-S0-1).
- [x] 3. `qml/helper/SignOutGuard.js` (pure) + `tests/tst_SignOutGuard.qml` (36 fns + 4 data fns = 53 cases). Node shim 53/53; shim proved on `tst_DescribeItem` 43/43; 16/16 hand mutants killed.
- [x] 4. `qml/pages/SignOutSheet.qml`, `Main.qml askLeave` (3 entry points + Back list), `BottomSheet.secondaryColor`.
- [x] 5. Docs: test plan, Skill 132, SKILLS-INDEX regenerated, AGENTS, README, test-plans index. Script tests 109/109.
- [x] 6. Pushed, PR #167 opened, rebased onto `main` @ `9c010f0` (#147 + #165 landed; Skills renumbered 136/137 because another session took 132-135). **CI green: 3247/3247** (QML 2174, Functions 866, Rules 106, E2E 101). Stacked PR #168: **3301/3301** (QML 2228).
- [x] 7. Stacked PR 2: `StockBatchStore._pendingMints` was tenant-blind and survives sign-out (a retry after an account switch could write a batch into the wrong tenant and hide the wrong product). `qml/helper/PendingMints.js` (pure) + `tests/tst_PendingMints.qml` (52 cases, Node shim 52/52, 15/15 mutants after one survivor was closed), store wiring (tag at `addBatch`, `due`, `sameTenant` in the callback, `tenantContextReady` retry, drop untagged on load), design, test plan, Skill 137, KNOWN-ISSUES, roadmap, AGENTS, README.
- [x] 8. PR #168 pushed (base = the sign-out branch), CI green. (Old suspect list, no longer needed: (a) the shim differs from QtTest for the 8 `_data` tests, (b) `AuthService.tenantContextReady.connect` signature in `StockBatchStore` (Skill 20 pattern, should be fine), (c) a test elsewhere that calls the real `_queuePendingMint` (grep found none).)

## State for the next session
- Taher: device-test `test-plans/2026-10-26-signout-guard-test-plan.md` (H1-H7, N1-N5, E1-E9) and `2026-10-26-pending-mints-tenant-scope-test-plan.md` (N1-N3, E1-E3), then merge #167, then #168 (restack its base to `main` first if #167 is squash-merged: `git rebase --onto origin/main <old #167 tip>`).
- Q-S0-1 open: add a "Try to sync first" button (`Gateway.drainNow()`) to the sheet? Claude recommends no for now.
- Not started, ranked: S2f-3 client wording (small, QML), restock operation R1-R6 (design approved on #147, needs a server `mint` kind), multi-role login L1/L2 (DRAFT, 8 open questions), S2f-6 server counters.

## NEXT after this
Taher: device-test the plan (H1-H7, N1-N5, E1-E9), merge. Then Q-S0-1 (add a "sync first" button?), PR #147 approval -> restock operation, S2f-3, multi-role login questions.
