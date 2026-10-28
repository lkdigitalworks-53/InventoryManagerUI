# CHECKPOINT — 2026-10-28 PR #167 sign-out sheet footer width (resume here)

**Branch:** `feat/2026-10-26-signout-guard` (PR #167). All work is committed and pushed to this branch (first fix `d35d33a`, review fixes in the next commit); nothing is held locally. (This branch already contains the merge of PR #168.)
**Commit identity:** `lkdwtaher@gmail.com`. PAT comes from the chat prompt only, passed with `git -c http.extraHeader="Authorization: Basic $(printf 'x-access-token:%s' "$PAT" | base64 -w0)"`, never in the remote URL, `.git/config`, the repo or memory. After a push `grep -c ghp_ .git/config` must print 0.
**Rules in force:** no build/run; no Qt in the sandbox (CI is the QML oracle); push without asking; short scope; honest trade-offs; tests + test plan for every change; caveman FULL for chat only; do not touch other PRs/branches.
**Skills used:** `superpowers:systematic-debugging`, `qt-development-skills:qt-qml`, `qt-development-skills:qt-ui-design`, `ponytail:ponytail`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-10-28-pr167-footer-width-prev-CHECKPOINT.md`.

## Bug (device test of PR #167)
"Stay signed in" button shows only "S…". Taher asked: shrink the discard / sign-out button, widen Stay, so the full text shows. Then review the change in the same pass, in the same PR.

## Root cause (systematic-debugging phase 1-2, from code, not a guess)
`PrimaryButton.contentItem` is an `Item` whose `Text` uses `anchors.fill`, so it reports NO implicit text width: the button's implicit width is only its padding (16 + 16 = 32 dp). `GhostButton.contentItem` is a plain `Text`, so its implicit width is the full label. In the `BottomSheet` footer both buttons are `Layout.fillWidth` with no preferred width: the layout starts from those implicit widths and splits the spare room equally. With the long label "Sign out and discard" (about 150 dp + 32) next to "Stay signed in", the primary starts at 32 dp and only gets half the spare room: roughly 80-90 dp on a 360 dp phone (ESTIMATE from assumed glyph widths, never measured), so the label ellipsizes to "S…". Sheets with a short secondary ("Cancel") never showed it; long primaries elsewhere ("Confirm & save", "Send reset link", "Import N rows") are at risk for the same reason.

## Steps
- [x] 1. Cloned, checked out PR #167 branch, read SignOutSheet, BottomSheet, GhostButton, PrimaryButton, wiring test. Root cause above.
- [x] 2. `qml/helper/SheetFooter.js` (pure `primaryFloor`) + `tests/tst_SheetFooter.qml` (21 functions; Node shim 21/21; 24/24 killable mutants killed, 1 equivalent).
- [x] 3. `BottomSheet.qml` footer: `TextMetrics` + floor on the primary button; wiring pins in `signOutGuardWiring.test.js` (43 -> 60/60).
- [x] 4. Docs: new test plan `2026-10-28-signout-sheet-footer-width-test-plan.md`, sign-out plan amended, design note, README, AGENTS, KNOWN-ISSUES, Skill 139, SKILLS-INDEX regenerated. Script suite 169/169.
- [x] 5. Node suite (169/169 before the review fixes, 171/171 after), commit, push: `d35d33a`.
- [x] 6. Review pass (independent read-only reviewer + own checks). Accepted and fixed: row is 320 not 312 in the tests (values unchanged), labels called estimates, sheet count 15 incl. SignOutSheet, 340 dp threshold withdrawn (340-370, to be measured, H2), StaffActionSheet is Cancel not Close, shim + mutation script committed in `scripts/probes/*.cjs`, font pin compares every `font.*` line, indent-fragile mutants made single-token (wiring 62/62). Documented not coded: spinner overlap when the primary sits exactly at its floor while busy. Rejected: reviewer's "Haiku trailer" note (this session is Sonnet 5.5). UNVERIFIED until device: binding-loop warning (plan E4), pixel result.
- [ ] 7. Read CI on the new head (CI only oracle for the QML tests); Taher device-tests.

## Open decisions for Taher (defaults applied, vetoable in the PR)
1. Q-FW-1: when both labels do not fit (narrow phone, Large font) the secondary ellipsizes first (applied). Alternative: stack the buttons vertically, primary on top (Claude recommends it if a 340 dp phone is a target; it changes the footer pattern). Test plan H2 asks for the phone's width in dp so this is decided on a number.
2. Footer fix lives in the shared `BottomSheet` (applied, 15 two-button sheets get a spot check) instead of only the sign-out sheet. Veto = move the floor behind an opt-in property.

## NEXT
CI on the new head; device-test H1-H4 + footer spot check + E4 (logcat); then merge order as in the sign-out plan.
