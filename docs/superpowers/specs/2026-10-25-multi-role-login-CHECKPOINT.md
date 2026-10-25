# CHECKPOINT — 2026-10-25 multi-role login + cross-actor tests (resume here)

**Branch:** `docs/2026-10-25-multi-role-login-pending` off `main` @ `b749a80`. Docs only. Own file (not root `CHECKPOINT.md`) so it cannot conflict with PR #159/#160/#161, which all rewrite root `CHECKPOINT.md`.
**Commit identity:** `taher.lkdw@gmail.com`. PAT only inline in the push command; `grep -c ghp_ .git/config` must print 0 after.
**Rules in force:** no build/run; no Qt in sandbox (CI is the oracle); push without asking; short scope per session; honest trade-offs, grill before deciding; tests + test plan for every change; caveman replies.
**Skills used:** `superpowers:brainstorming` (HARD-GATE: no code until design approved), `ponytail:ponytail-audit` (scoped to the auth/role/provisioning path), `qt-qml`, `qt-ui-design` (no QML/UI written yet).

## Why
Taher device-testing PR #159 (rules deployed): owner flows fine, "login as staff" cases not testable because the app cannot create or use any non-owner login. Asked: confirm documented, document if not; build login as other roles; test actions across tenant users.

## Steps
- [x] 1. Read project notes, cloned, found PR #159 branch `fix/2026-10-24-s2f1-membership-authority`.
- [x] 2. Traced cause: `Gateway.provisioningAvailable = false` (`Gateway.qml` L41) gates BOTH Add Staff login and Invite by UID via `Gateway.provisionMember`. Server `provisionMember` exists (`functions/index.js` ~L710). Flag never flipped.
- [x] 3. Doc check: only scattered "dormant until login provisioning ships" lines; no entry of its own -> NOT documented. Added `KNOWN-ISSUES.md` entry + `AGENTS.md` status row + this file.
- [x] 4. Taher (2026-10-25): wants the FULL design brainstorm captured, notes in KNOWN-ISSUES/AGENTS, and will pick up AFTER compliance features. So no live grilling this session.
- [x] 5. DRAFT design written `specs/2026-10-25-multi-role-login-design.md` (D1-D8 open, slices L1-L6, matrix X1-X13, questions Q0-Q7). Brainstorming gate NOT passed: no design approved, no plan, no code.
- [ ] 5b. (resume) Answer Q0-Q7 one at a time, revise design, get approval, then `writing-plans`.
- [ ] 6. Implement in slices, each its own branch/PR.

## Open questions (asked one at a time, answers recorded below)
None. All of Q0-Q7 live in the design doc section 8.

## Resume
Check PR #159/#160/#161 merged first (design assumes member-doc authority). Then Q0 (verify refresh behaviour in code), then Q1...
