# CHECKPOINT — 2026-10-24 S2f authz hardening (resume here)

**Branch:** `fix/2026-10-24-s2f1-membership-authority` off `main` @ `b749a80` (PR #156 merged). PR-B (`fix/2026-10-24-s2f2-members-rules`) will be STACKED on this branch.
**Commit identity:** `taher.lkdw@gmail.com`. PAT only inline in the push command; after push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in sandbox (CI is the QML + rules-emulator oracle); push without asking; short scope per session; honest trade-offs; tests + test plan for every change; caveman FULL for chat only.
**Skills used:** `superpowers:brainstorming` (design doc, decisions marked vetoable), `ponytail`, `qt-qml` and `qt-ui-design` (no QML/UI in PR-A or PR-B; only a client wording follow-up is queued, S2f-3).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-24-s2c-prev-CHECKPOINT.md`.

## Why
PR #156 sweep proved F1 (any member can rewrite `members`) and F2 (suspended member keeps direct access). Re-reading the gateway while designing the fix found F3, worse than both: `deriveContext` trusts the client-writable `users/{uid}` doc when no member doc exists. Proven red in the handler harness (non-member got 200 on `recordMutation` in another tenant, role `owner`).

## Steps
- [x] 1. Read memory + sweep report, cloned, cut branch, archived previous checkpoint.
- [x] 2. Probe F3 in the handler harness (`/tmp` only): users doc `{tenantId: victim, role: owner}`, no member doc -> 200. Red.
- [ ] 3. Design doc `specs/2026-10-24-s2f-authz-hardening-design.md` (findings, options, slices, decisions).
- [ ] 4. PR-A: fix `deriveContext` (member doc required, role from member only, status gate), table test over all 10 handlers, test plan, docs.
- [ ] 5. Push PR-A.
- [ ] 6. PR-B (stacked): rules F1 + F2 + tests for users/tenants/members blocks, test plan, docs.
- [ ] 7. Push PR-B.

## NEXT
See the design doc section "Slices". Not started: S2f-3 (client wording), S2f-4 (lock orders/staff/suppliers/removed_staff), S2f-5 (allow-list wildcard).
