# CHECKPOINT — 2026-10-19 P1 S2 design session (resume here)

**Branch:** `docs/2026-10-19-p1-s2-design`, cut from `main` @ `fe9aa86` (PR #149 merged).
**Commit identity:** `tsadmin@gmail.com` (this session's rule; earlier branches used other ids, left as is). PAT only in the push command, never in a file or git config; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** do not build/run the app; no Qt in the sandbox (CI is the QML oracle); push without asking, Taher reviews in the PR; short scope (token budget, multi-account hand-off); honest trade-offs and grill before decisions; tests + test plan for every code change; caveman FULL.
**Skills used:** `brainstorming` (path: ARCHITECTURAL, hard gate: no code before approval), `qt-qml`, `qt-ui-design`, `ponytail`. No code this session.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-18-p1-s1b-prev-CHECKPOINT.md`.

## Why this item
S1b checklist (deploy + device test) is Taher's and in progress. Next item in the P1 design (section 4) is S2. It was never designed (spec section 8 leaves UX open), so this session designs it.

## Steps
- [x] 1. Read skills, cloned repo, read S1b checkpoint, P1 design spec, branch cut.
- [x] 2. Code audit (findings in the design doc section 1): direct mode only in `recordMutation`/`recordEdit`/`recordMutations`; `runCutover` has no client caller; no client writes `inventory` outside the Gateway; stock paths (`restock`, `deductStock`, `creditStockNoBatch`) all send plain deltas so the server derives `adjustment`; `OutboxStore.enqueueDelta` SUMS coalesced deltas, so `movements` must be concatenated (new trap).
- [x] 3. Draft design `docs/superpowers/specs/2026-10-19-p1-s2-design.md`: split S2a-S2e, order, trade-offs, open questions Q1-Q5. README pointer added.
- [x] 4. Committed and pushed (no PR opened: Taher reviews the branch).
- [ ] 5. **Taher answers Q1-Q5** (asked in chat). Then update the design to rev 2 = approved.
- [ ] 6. After approval, next session implements the FIRST slice only (proposal: S2b, server-only deletion), tests + test plan per slice.

## Open items / risks
- Q1-Q5 in the design doc section 3 are unanswered.
- S2d/S2e must not ship before the S1b deploy + device checklist passes (R3).
- S2a rewrites `tst_Gateway.qml` cases that force `"direct"`: CI is the only oracle.
- Deleting the `runCutover` export does not delete the deployed function; Taher confirms the prompt on `firebase deploy`.

## NEXT
Get answers to Q1-Q5, bump the design to rev 2, then implement S2b on a new branch off `main`.
