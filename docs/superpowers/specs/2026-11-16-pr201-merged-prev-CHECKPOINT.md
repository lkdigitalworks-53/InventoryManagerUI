# CHECKPOINT: 2026-11-15 PR #201 (AP2) deep review sweep + rebase onto #200 - resume here

**Branch:** `feat/2026-11-15-ap2-add-product-client-plan` (PR #201). Rebased onto `main` @ `5dee56d` (#200 merged) on 2026-11-15; the four original commits were replayed (SHAs changed, force-with-lease, on Taher's explicit instruction). Contract: `docs/superpowers/specs/2026-11-13-add-product-atomic-operation-design.md` section 9. This slice's design: `docs/superpowers/specs/2026-11-15-ap2-add-product-client-plan-design.md`.
**Commit rule (current):** every commit message carries a line `lkdigitalworks@gmail.com`; git user `Taher (via Claude session) <lkdigitalworks@gmail.com>`. The four ORIGINAL commits of this PR carry `allibaas52@gmail.com` (older instruction); not rewritten again. PAT per command via `git -c http.extraHeader`, never in `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; no parallel agents this sweep. Node tests of `functions/` DO run here (`cd functions && npm ci && node --test`, 1882/1882 on this branch).
**Previous checkpoints archived:** `specs/2026-11-15-pr199-merged-prev-CHECKPOINT.md` (AP2 start), `specs/2026-11-15-pr200-merged-prev-CHECKPOINT.md` (main's picker S5a checkpoint, archived at this rebase).
**Test plan:** `docs/superpowers/test-plans/2026-11-15-ap2-add-product-client-plan-test-plan.md`.

## Step 2 arc
AP1 server (merged #199). **AP2 client pure layer (THIS BRANCH, dormant):** keys, `AddProductPlan.js` (`build`, `reflect`, `neutralisePlaceholders`), `FailureCause.forAddProduct`, `DescribeItem` label. AP3 = wire `InventoryStore.addProduct` + `AddProductDialog` + `DataModel` route (read design section 6 FIRST, incl. the new `malformed-results` bullet). AP4 = device test.

## This session's steps (PR #201 sweep)
- [x] 0. Clone (public, no token in config), memory, skills (requesting-code-review, qt-qml-review, ponytail-audit), PR #201 read: 22 files +1494 -40, `mergeable_state: dirty`, CI green on `ba29ccc`.
- [x] 1. Rebase onto main: conflicts were `CHECKPOINT.md` (kept this branch's, main's archived above) and `SKILLS.md` / `SKILLS-INDEX.md` (main took Skills 169 and 170; AP2's entry renumbered 170 -> 171 in SKILLS, the index, AGENTS and KNOWN-ISSUES 45). Pushed at once (`b211dcf`).
- [x] 2. Phase 1 lint on the four touched QML tests: 71 hits on added lines = 67 JS-1 (`var`, house style), 3 JS-2 (linter false positive on `!==`), 1 STY-1 (no `id: root`, house style). No code change.
- [x] 3. Phase 2 deep review, single-threaded. Read: `AddProductPlan.js`, the three helper diffs, the server `operationLogic.js` validator and apply path, `DocLimits`, both Node test files, the QML twin, design, test plan, all `tx-c-` / `act-` consumers. Domains 2-5 of the QML review (layout, loaders, delegates, states) are N/A: this PR has no visual QML. Chain probe: 4000 adversarial inputs through build, real validator, real apply, reflect, stored-doc round trip: 0 failures.
- [x] 4. F1 FIXED (`49abb69`, pushed): a timestamp or day with only the right shape passed `build`; now a real instant (`_realTime`). Test first (red), then fix; 4 mutants (3 killed, 1 proven equivalent); QML twin rows added.
- [x] 5. F2 FIXED (docs, this commit): the old add path never had the `{{prd}}` hole; KNOWN-ISSUES 41, STATUS and the test plan's on-device step corrected. Counts refreshed (1882, 43, 60, 68 rows, 39 mutants); KNOWN-ISSUES 46 records the sweep; design section 6 gets the `malformed-results` bullet; Skill 171 rule 5 extended.
- [x] 6. CI READ on `49abb69` (code commit): all 4 test jobs success, incl. real QML Tests; deploy jobs skipped. Recorded in test plan section 5. Docs-only head `efd53fb` had no runs yet when read.
- [x] 7. Grill questions answered 2026-11-16 (recommendations taken, recorded in design, KNOWN-ISSUES 46a and above).
- [ ] 8. Taher reviews and merges PR #201. Then AP3 (design section 6 is the checklist).

## Open (judged, not changed) - KNOWN-ISSUES 43-46
43 `RestockPlan` accepts any non-empty `now` (recipe: AP2's `_realTime`). 44 dialog values the planner refuses = AP3 checklist. 46a `reflect` can refuse an answer the server has already committed: AP3 must define the dialog's behaviour. 46b restock REFUSES token-equal text, add NEUTRALISES it.

## Decisions (Taher, 2026-11-16: "go as per recommendation")
1. D-AP2-2 DECIDED: the planner refuses bad numbers and tax outside 0..100.
2. D-AP2-5 DECIDED: typed text is trimmed before storing.
3. D-AP2-7 DECIDED: the `created` row stores exact stock. AP3 checklist: check how the Purchased analytics (`BreakdownMath.js:209`, `TransactionStore.qml:430,444`) read a fractional `created` quantity.
4. `malformed-results` after a committed add DECIDED: AP3 refreshes the product list from the server and offers no plain retry (a new tap = a new key = a second product). `reflect` is NOT made stricter.

## NEXT (if this session stops)
Taher reviews and merges #201; then AP3. Continue at the first unchecked step. Each commit is independent. Do not force-push again without Taher's instruction.
