# CHECKPOINT: 2026-11-24 NO3b New Order price field - resume here

**Branch:** `feat/2026-11-24-no3b-order-price-cap` (cut from `main` @ `fc4eee5`, #217 NO3a merged and device tested by the owner).
**Ask (2026-11-24):** take the next atomic-operations roadmap task, design it in the session, implement, document out-of-scope findings in the relevant doc, no parallel agents, quality and robustness first, show done/next at the end. Full caveman mode in chat; skills brainstorming, qt-qml, qt-ui-design, ponytail.
**Commit rule:** every commit message carries `lkdwtaher@gmail.com` (project instructions). Earlier PRs carry other addresses (KNOWN-ISSUES 111, 118, 125); history is not rewritten.
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`; keep scope short so another account can take over.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-24-pr217-merged-prev-CHECKPOINT.md`.

## Roadmap read (2026-11-24)
Done: step 1 restock, step 2 add product (AP4 device pass still the owner's), step 3 NO1 server, NO2 planner, NO3a wire (#217, device tested). Open: NO3b (this branch), then `_tryAdjustOrder` / `_reverseCompletedOrder` / `completeImportedOrder` (each needs a design and rulings, Q-NO3-1), step 4 import chunking (G5, G9 need designs).

## Steps
- [x] 0. Clone, memory + STATUS + CHECKPOINT read, roadmap read, KNOWN-ISSUES 114 read.
- [x] 1. Design `specs/2026-11-24-no3b-order-price-cap-design.md` (D-NO3b-1..8, Q-NO3b-1..3; decisions defaulted, vetoable in the PR, as ordered).
- [x] 2. Code: `OrderFlow.priceEdit/priceText`, `AddProductFlow.moneyState` alias, `NewOrderDialog` (`_setLinePrice`, `cartRow.priceError`, message Text, border, description, focus clear, index guard).
- [x] 3. Tests: `orderFlow` F-8..F-13, `orderPriceCap` P-1..P-7 (new), `newOrderDialog.guard` D-7..D-9, `tst_OrderFlow.qml` +5 (CI), `pickerS5e3Names` S5E3-21 updated. P-5 found a real throw (NaN index), fixed.
- [x] 4. Hand mutants 24 of 24 killed (one runner timeout left a mutant applied; restored, diff checked).
- [x] 5. Docs: test plan (+README row), KNOWN-ISSUES 114 closed + 142-147, Skill 189 + index, AGENTS, STATUS 21. README unchanged on purpose (no feature-level change).
- [x] 6. Functions 2383/2383 RUN (after `npm ci`), scripts 1199/1199, skills index current.
- [ ] 7. Owner: review in the PR; answer Q-NO3b-1..3 and Q-NO3-1; confirm the commit email; device checks 1 to 20 of the test plan. If CI is red on `tst_OrderFlow.qml`, the node twins (`orderFlow` F-8..F-13) already pass: read the first failure.

## Next slice
NO3c (optional, small): the Edit Order sheet's price and discount fields (`OrderDetailDialog` `_commitPrice` ~759, `_commitDiscount` ~854) with `OrderFlow.priceEdit` and a row message (KNOWN-ISSUES 143). Then design `_tryAdjustOrder` (Q-NO3-1).
