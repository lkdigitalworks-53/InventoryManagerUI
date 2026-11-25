# CHECKPOINT: 2026-11-25 NO3b review sweep (PR #219) - resume here

**Branch:** `feat/2026-11-24-no3b-order-price-cap`, PR #219. Rebased onto `main` @ `4ce6a48` (#220) on 2026-11-25; NO3b docs renumbered to KNOWN-ISSUES 150-161 and Skill 191 (main owns Skill 190 and KNOWN-ISSUES up to 149).
**Ask (2026-11-25):** full deep review of PR #219, fixes in the same PR, no parallel agents, recommended defaults on open questions, quality and robustness first, show done/next at the end. Caveman chat mode.
**Commit rule:** every commit message carries the email of the account that made it (earlier sessions `lkdwtaher@gmail.com`; 2026-11-25 session `lkdigitalworks@gmail.com`).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; PAT per command, never in `.git/config`.
**Previous checkpoints archived:** `docs/superpowers/specs/2026-11-24-pr217-merged-prev-CHECKPOINT.md`, `...-pr218-merged-prev-CHECKPOINT.md`, `2026-11-25-pr220-merged-prev-CHECKPOINT.md` (main's S5f checkpoint, replaced by this one in the rebase).

## Steps
- [x] 0. First session: design D-NO3b-1..8, code, tests, docs, PR #219 (`de893dc`).
- [x] 1. Sweep: merged `main` (4 doc conflicts, renumbered).
- [x] 2. Review (QML linter + the six qt-qml-review domains by hand, ponytail audit of the diff, callers traced to `OrderPlan`).
- [x] 3. Fixes (design section 8, KNOWN-ISSUES 156): dialog-held refusals, `_settlePriceEdit`, submit blocked on an unread refusal, order-independent focus handler, plain text after Enter, stale `OrderPlan` comment.
- [x] 4. Tests: functions 2420/2420 RUN, scripts 1199/1199, 29/29 hand mutants.
- [x] 5. Docs: design, test plan (25 device checks), README, KNOWN-ISSUES, Skill 191, AGENTS, STATUS.
- [x] 6. Pre-rebase: pushed `7a31861` (now `41fc180`); CI on that OLD hash was 6089/6089 (QML 3416, Functions 2420, Rules 129, E2E 124). That result does NOT cover the rebased code.
- [x] 7. Rebase onto `main` @ `4ce6a48` (#220) with `git rebase`: the merge commit of #218 dropped (already in main), 3 commits replayed. Conflicts in 7 doc files, merged by keeping main's entries and appending ours (CHECKPOINT.md: branch version); renumbered every reference on lines this branch added. NO code file conflicted (`NewOrderDialog.qml` auto-merged with S5f/S5e-3c). Not run: tests (CI is the oracle).
- [ ] 8. CI on the rebased head: NOT READ YET. Read it first (QML, Functions, Rules, E2E); #220 changed `PhotoSourceSheet.qml` and `pickerS5e3*` tests that this branch also touches (`pickerS5e3Names.test.js` auto-merged).
- [ ] 9. Owner: review the PR (veto D-NO3b-9..11 if wanted), device checks 1 to 25.

## Next slice
NO3c (small): Edit Order sheet price and discount fields with `OrderFlow.priceEdit` and the same submit rule (KNOWN-ISSUES 151), plus the New Order discount field (154, 158). Then design `_tryAdjustOrder` (Q-NO3-1 default). Later: 2-decimal limit across the three money fields (Q-NO3b-2).
