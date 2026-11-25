# CHECKPOINT: 2026-11-25 NO3b review sweep (PR #219) - resume here

**Branch:** `feat/2026-11-24-no3b-order-price-cap`, PR #219. `main` @ `eaa0934` (#218) merged in; NO3b docs renumbered to KNOWN-ISSUES 146-157 and Skill 190.
**Ask (2026-11-25):** full deep review of PR #219, fixes in the same PR, no parallel agents, recommended defaults on open questions, quality and robustness first, show done/next at the end. Caveman chat mode.
**Commit rule:** every commit message carries `lkdwtaher@gmail.com` (project instructions).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; PAT per command, never in `.git/config`.
**Previous checkpoints archived:** `docs/superpowers/specs/2026-11-24-pr217-merged-prev-CHECKPOINT.md`, `...-pr218-merged-prev-CHECKPOINT.md`.

## Steps
- [x] 0. First session: design D-NO3b-1..8, code, tests, docs, PR #219 (`de893dc`).
- [x] 1. Sweep: merged `main` (4 doc conflicts, renumbered).
- [x] 2. Review (QML linter + the six qt-qml-review domains by hand, ponytail audit of the diff, callers traced to `OrderPlan`).
- [x] 3. Fixes (design section 8, KNOWN-ISSUES 152): dialog-held refusals, `_settlePriceEdit`, submit blocked on an unread refusal, order-independent focus handler, plain text after Enter, stale `OrderPlan` comment.
- [x] 4. Tests: functions 2420/2420 RUN, scripts 1199/1199, 29/29 hand mutants.
- [x] 5. Docs: design, test plan (25 device checks), README, KNOWN-ISSUES, Skill 190, AGENTS, STATUS.
- [x] 6. Pushed `7a31861`; PR text updated. CI on it: 6089/6089 (QML 3416, Functions 2420, Rules 129, E2E 124), deploy skipped, PR mergeable clean. This checkpoint-only commit goes on top (its CI not read).
- [ ] 7. Owner: review the PR (veto D-NO3b-9..11 if wanted), device checks 1 to 25.

## Next slice
NO3c (small): Edit Order sheet price and discount fields with `OrderFlow.priceEdit` and the same submit rule (KNOWN-ISSUES 147), plus the New Order discount field (150, 154). Then design `_tryAdjustOrder` (Q-NO3-1 default). Later: 2-decimal limit across the three money fields (Q-NO3b-2).
