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
- [x] 2. Rebuilt PR tree on `main`: design 7b (S2f interaction) + Q-A8, test plan RP1-RP4, status doc section 6 + G11, KNOWN-ISSUES, E2E roadmap, test-plans README row, Skills 122/123 renumbered to 132/133 (main is at 131).
- [x] 3. Pushed (see Resume).
- [ ] 4. Taher: answer Q-A7 (order, S0 first?) and Q-A8 (accept `counters`/F7 open through the arc); approve or revise the spec on #147.
- [ ] 5. After approval ONLY: invoke writing-plans for S0 (sign-out guard). Do not invoke it before.

## Open P1 tail (not gates): #165 (S2f-7), S2f-3 client wording, owner-demotion slice, S2d, S2e (parked on CA).
## To verify later: R3 must confirm the client `recordOperation` builder passes `movements` through untouched. R2 start: `git diff --stat origin/main...<branch>` for overlap (Skill 122).
