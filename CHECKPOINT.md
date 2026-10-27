# CHECKPOINT — 2026-10-27 PR #168 final sweep (resume here)

**Branch:** `fix/2026-10-26-pending-mints-tenant-scope` (PR #168, STACKED on #167 `feat/2026-10-26-signout-guard`). Work is committed and pushed to this branch; nothing is held locally.
**Commit identity:** `lkdwtaher@gmail.com` (Taher's instruction, 2026-10-27). PAT comes from the chat prompt only: pass it with `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)"`, never in the remote URL, `.git/config`, the repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in the sandbox (CI is the QML oracle); push without asking; short scope per session; honest trade-offs; tests + test plan for every change; caveman FULL for chat only; do not touch other PRs/branches (#167 has its own sweep branch).
**Skills used:** `superpowers:requesting-code-review` (one read-only reviewer subagent on tests + docs), `ponytail:ponytail-audit`, `qt-development-skills:qt-qml-review` (lint script on the changed lines; agents 2/4/5 N/A: no layout, delegate or state change).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-27-pr168-sweep-prev-CHECKPOINT.md`.

## Steps (this session)
- [x] 1. Cloned, fetched `pull/168/head`, checked out the PR branch, read memory + checkpoint. Scope = commit `feea99f` only.
- [x] 2. Read `PendingMints.js`, the store diff, `nextBatchId` / `FirebaseService.mintCounterValue` / `_splitPath`, `Main.qml` resync, tests. Lint on changed lines: only false positives.
- [x] 3. Findings and fixes (all in this PR):
  - F1 MUST: `addBatch` success path wrote the batch into the NEW tenant if the account switched while the mint was out (mint retries re-resolve the tenant per attempt). Fixed: capture + `!==` re-check, queue for the old tenant.
  - F2 MUST: the PR's `tenantContextReady` retry ran before `Main.qml`'s resync (store handler connects first), so `nextBatchId` seeded from an EMPTY ledger. Fixed: hook removed; `_loadedTenant` + `sameTenant` gate; retry starts from the ledger load's completion; `clear()` / `_resetAndFetch()` reset it.
  - F3 SHOULD: guard in `_queuePendingMint` was untested and `"3"` qty was queued then dropped on relaunch. Fixed: pure `PendingMints.make`.
  - F4 SHOULD: pre-fix and damaged queue items were destroyed. Fixed: quarantine in `rejectedJson` (`appendRejected`, newest 50, raw text of a non-list file); non-list JSON now quarantined too.
  - F5 NICE: `has()` allocated per picker row and matched `undefined`. Fixed.
  - Tests: 52 -> 129 cases (64 functions), mutation 31/31 killed, drift note on `tst_PendingMintAndTopUpSafety`.
  - Docs: design (sections 3-6), test plan rewritten (E1 driver-only, E3 recipe, new E4-E8, known limitation), KNOWN-ISSUES, AGENTS, README, roadmap, Skill 137 (rules 5, 7 rewritten, 9-11 added) + index regenerated (`node .github/scripts/skills-index.js --write`), script tests 109/109.
- [x] 4. Commit + push (see git log). Wrong pointer in the OLD commit message `feea99f` ("Skill 133") is NOT rewritten (pushed history): the skill is 137.
- [ ] 5. Read CI on the new head. Suspects if red: `tst_PendingMints.qml` (never run under real QtTest; the Node shim differs for `_data` rows and `compare` of objects), `StockBatchStore.qml` syntax (`throw new Error` in `_loadPendingMints`, `var id = tenantChanged ? "" : mintedId`). Recount from the CI comment, do not trust predictions.
- [ ] 6. Taher: device-test the plan (H1-H3, N1-N4, E2-E8), merge #167, restack #168 (`git rebase --onto origin/main <old #167 tip>` if #167 is squash-merged), merge #168.

## Open decisions for Taher (defaults applied, vetoable in the PR)
1. Pre-fix / damaged queue items: quarantine (applied, recommended) or adopt into the first tenant that signs in? Design doc section 6.
2. Q-S0-1 (from #167): add a "Try to sync first" button to the sign-out sheet? Claude recommends no for now.

## Not done on purpose
`without(tenant, id)`; UI or reader for the quarantine; expiry of other tenants' items; user-level (staff vs owner) scoping; server-side queue (restock design, PR #147).

## NEXT (suggested order)
CI on this head, device test, merge #167 then #168. Then: S2f-3 client wording, restock operation R1-R6 (design approved on #147, needs a server `mint` kind), multi-role login L1/L2 (DRAFT, 8 open questions), S2f-6 server counters.
