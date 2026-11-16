# CHECKPOINT: 2026-11-13 P1 S2e-1 reason policy + server-stamped cost value - resume here

**Branch:** `feat/2026-11-13-p1-s2e1-reason-policy-and-cost-snapshot`, STACKED on `feat/2026-11-12-p1-s4b1-register-client-engine` (PR #198, CI green, not merged at last look). PR base = that branch; GitHub retargets to `main` when #198 merges. Design: `docs/superpowers/specs/2026-11-13-p1-s2e1-reason-policy-and-cost-design.md`. Test plan: `docs/superpowers/test-plans/2026-11-13-p1-s2e1-reason-policy-and-cost-test-plan.md`.
**Commit identity:** `taher.lkdw@gmail.com` as git user AND last line of every commit message. PAT from the chat prompt only, passed per command, never stored in `.git/config`, the repo or memory.
**Rules in force:** no build or run; no Qt in the sandbox (CI decides); always a branch; push without asking; tests + test plan for every change; out-of-scope findings to `docs/superpowers/KNOWN-ISSUES.md`.
**Taher's decisions this slice (2026-11-13):** adjustment stays allowed with an OPTIONAL reason; cost value = the product's cost price (field `price`; I decided: stamped by the SERVER at write time, no GST detail yet); mandatory reason for the sensitive kinds, chosen by me from research (CGST 17(5)(h)): loss, theft, destroyed, write_off, gift; free_sample optional; the app serves any kind of business vendor, not only Al-Libaas.
**Skill number:** 173 (172 is S4b-1, PR #198).

## Steps
- [x] 0. Read memory, repo state, movementLogic / gatewayLogic / operationLogic write paths, FailureCause terminal-code list.
- [x] 1. Server: `REASON_REQUIRED`, `MIN_REASON_LENGTH`, `VALUE_KINDS`, `unitCostOf`, `valueFor` in `functions/lib/movementLogic.js`; `movement-reason-required` in `validateMovements`; `unitCost` passed to `buildRows` in `gatewayLogic.applyDelta` and `operationLogic.applyOperation`.
- [x] 2. Client mirror in `qml/helper/StockMovements.js` (`reasonRequired`, `reasonProblem`, validate rule); `movement-reason-required` added to `FailureCause.js` terminal list + `tst_FailureCause.qml`.
- [x] 3. Tests: `functions/test/reasonPolicy.test.js` RP-01..04 (battery, parity matrix + 3000 monkey, 27 mutants), 10 wiring tests in `movementWiring.test.js`, 1 handler test, QML twin cases in `tests/tst_StockMovements.qml`. Existing fixtures that used a required kind without a reason were given one (no assertion weakened). functions 1686/1686, scripts 1061/1061.
- [x] 4. Docs: design, test plan + index, KNOWN-ISSUES (S2e-1 section, 14 items), Skill 173 + index, README, AGENTS.
- [ ] 5. Push (done after this edit), open PR (base = S4b-1 branch), read CI, report.

## NEXT
Read CI. Then S2e-2 (pickers on the product sheet / stock edit with the reason field and `reasonProblem`), S4b-2 (register page with columns Opening | Receipts | Supplies | Other outward | Stock correction | Closing). Pending Taher: which of the two first; merge order #196 -> #198 -> this PR.
