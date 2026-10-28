# CHECKPOINT — 2026-10-28 S2f-3 access wording + access-blocked screen (resume here)

**Branch:** `feat/2026-10-28-s2f3-access-wording` (from `main` @ `69e7381`). Push after every phase; nothing is held locally once a phase is marked pushed.
**Commit identity:** `dextran52@gmail.com` (Taher, 2026-10-28; the previous checkpoint said another address, this instruction wins). PAT comes from the chat prompt only, passed with `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)"`, never in the remote URL, `.git/config`, the repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in the sandbox (CI is the QML oracle); push without asking; short scope; honest trade-offs; tests + test plan for every change; caveman FULL for chat only; do not touch other PRs/branches (the sibling branch `feat/2026-10-28-p1-s2d1-movement-kinds` is another session's: S2d-1, no file overlap except this CHECKPOINT).
**Skills used:** `superpowers:brainstorming` (design decisions below, vetoable in the PR), `qt-development-skills:qt-qml`, `qt-development-skills:qt-ui-design`, `ponytail:ponytail`, `caveman:caveman` (chat only).
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-28-pr167-merged-prev-CHECKPOINT.md` (PR #167 is merged into `main`).

## Why S2f-3 and not S2f-6
`restock-atomic-operation-design.md` says S2f-6 `counters` locking IS the `mint` op of the restock design (R2): "Build it once, here. Do not build a separate S2f-6." So S2f-6 is not an independent slice, it is a big server slice with no design sign-off yet. S2f-3 is client only, designed (`2026-10-24-s2f-authz-hardening-design.md` row S2f-3), needs no deploy, and closes finding 12 of the PR #159 sweep.

## Root cause (read from code, not guessed)
`AuthService._loadUserProfile` takes tenant and ROLE from the self-writable `users/{uid}` doc and, when that doc carries a role, never reads the member doc at all (`tenantContextReady(tenantId, role)` fires at once). A suspended or removed member therefore gets the full app (role from the users doc), and every read and write is refused: empty lists, writes stuck on HTTP 403. `_loadMembership` (only used when the users doc has no role) ignores `status`, defaults a missing role to `staff`, and any failure there routes to the "Create your workspace" screen. `FirebaseService.get` drops the HTTP status, so a 404 (member doc deleted) cannot be told from a network error. Rules already let a member read ITS OWN member doc when suspended (pinned by `F2 ... can still read ITS OWN member doc`).

## Steps
- [x] 1. Cloned, branched, read S2f design, multi-role design, AuthService, FirebaseService, rules, Main, TenantSetupPage, test harness. Root cause above.
- [x] 2. Design doc + decisions D1-D9 (`docs/superpowers/specs/2026-10-28-s2f3-access-wording-design.md`), all vetoable defaults.
- [x] 3. `qml/helper/AccessState.js` + `tests/tst_AccessState.qml` (44 functions, Node shim 44/44, 55/56 mutants, 1 equivalent).
- [x] 4. `FailureCause.forWriteError` 403 wording + `tst_FailureCause.qml` U14 + quotes in the 2026-10-13 plan/design.
- [x] 5. `FirebaseService.get` passes HTTP status; `AuthService._verifyMembership`, `accessBlock`, `recheckAccess`, `_profileSeq`; no role defaults left.
- [x] 6. `qml/pages/AccessBlockedPage.qml` + `Main.qml` (z 300). CMake globs, nothing to edit.
- [x] 7. `.github/scripts/__tests__/accessBlockWiring.test.js` (21: rules + 17 mutants + 3 parity), rules tests (+2 definitions).
- [x] 8. Docs: test plan, README, AGENTS, KNOWN-ISSUES (3 entries), S2f design row, Skill 140, SKILLS-INDEX regenerated.
- [x] 9. Script suite 192/192 locally; committed; pushed (see git log on the branch).
- [ ] 10. Read CI on the head (QML + rules tests are CI-only); Taher device-tests the plan; review the PR.

## Open decisions for Taher (defaults applied, vetoable in the PR)
D1 extra member-doc read per login/reconnect; D3 dedicated screen; D4 failed check keeps a previously verified member in (alternative: block on any failure); D5 no "create new workspace" for a removed member. Details in the design doc.

## Found, not fixed (KNOWN-ISSUES)
Users-doc read failure shows "Create your workspace"; mid-session changes noticed only at reconnect/launch; dead `AuthService.setTenantContext`.

## NEXT
Read CI. Then, in order: users-doc failure fix (small, `get` now has the status), L3 session lifecycle (refresh/resume re-check + distinct server codes), S2f-6 only together with the restock `mint` design approval. Another session on `feat/2026-10-28-p1-s2d1-movement-kinds` (S2d-1) also edits `CHECKPOINT.md`: on merge keep the incoming one, archive this one to `docs/superpowers/specs/` (rebase rule).
