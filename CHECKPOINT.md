# CHECKPOINT — 2026-10-26 atomic-ops design refresh for P1/S2f (resume here)

**Branch (current):** `docs/2026-10-16-restock-atomic-operation-design` (PR #147, docs only). Tree rebuilt on `main` @ `b494d52` and joined with `merge -s ours` (Skill 121), no force-push. Local backup of the old tip: `backup/pr147-pre-rebase` (not pushed).
**Commit identity:** `tsadmin@gmail.com`. PAT only inline in the push command; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the oracle); push without asking; short scope; honest trade-offs, grill before decisions; tests + test plan for every change (docs-only here: none); caveman FULL for chat only.
**Skills used:** `superpowers:brainstorming` (hard gate: no plan, no code before spec approval).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-26-pr147-prev-CHECKPOINT.md` (S2f authz hardening; S2f-7 is #165).

## Why
Design v2 (2026-10-16) predates S2f. Taher confirmed 2026-10-26: S2f rules + functions deployed, device passes N6/E4 done. The design needed to say how `mint` relates to S2f-6, what stays on the client-writable allow-list, and that #146 is merged.

## Steps
- [x] 1. Verified in code: `operationLogic.js:164-167` honours per-op `movements`, default for unknown opType is `adjustment`; rules allow-list is `activity_log, config, counters, _migrations`.
- [x] 2. Rebuilt PR tree on `main`: design 7b (S2f interaction) + Q-A8, test plan RP1-RP4, status doc section 6 + G11, KNOWN-ISSUES, E2E roadmap, test-plans README row, Skills 122/123 renumbered to 133/134 (main is at 131; Skill 132 is taken by the S0 branch `feat/2026-10-26-signout-guard`).
- [x] 3. Pushed (see Resume).
- [x] 3b. Q-A7 answered by action: Taher started S0 in a separate session (branch `feat/2026-10-26-signout-guard`, no PR yet when checked). 4b is superseded by that design where they differ (D-S0-3).
- [x] 4. Q-A8 answered by Taher 2026-10-26: "yes keep it as recommended". Taher merges #147 first (his decision), S0 rebases after (Skill 131, keep Skill 132).
- [x] 4b. #147 final: CI green, mergeable clean, `main` already an ancestor of the branch.
- [ ] 5. After #147 is merged: invoke writing-plans for R1+R2 (counter path, seed fallback, `mint` op) in a NEW session on a NEW branch off `main`. Do NOT touch the S0 branch/session. S0 has its own plan.

## Open P1 tail (not gates): #165 (S2f-7), S2f-3 client wording, owner-demotion slice, S2d, S2e (parked on CA).
## To verify later: R3 must confirm the client `recordOperation` builder passes `movements` through untouched. R2 start: `git diff --stat origin/main...<branch>` for overlap (Skill 122).
