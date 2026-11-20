# CHECKPOINT: 2026-11-20 picker S5c (touch targets, Back route, in-stock double toggle) - resume here

**Branch:** `feat/2026-11-20-picker-s5c-touch-back-toggle` (cut from `main` @ `0ce6534`, PR #202 S5b merged).
**Commit rule:** every commit message carries `taher.lkdw@gmail.com` (task prompt of 2026-11-20).
**Rules in force:** no build or run; no Qt in the sandbox (CI is the oracle); always a branch; push without asking; tests + test plan for every change; out-of-scope findings go to `docs/superpowers/KNOWN-ISSUES.md`; PAT per command via `git -c http.extraHeader`, never in `.git/config`.
**Previous checkpoint archived:** `docs/superpowers/specs/2026-11-20-pr202-merged-prev-CHECKPOINT.md`.
**Plan:** `docs/superpowers/plans/2026-11-20-product-picker-v2-s5c-touch-back-toggle.md`. **Test plan:** `docs/superpowers/test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5c rows).
**Skills used:** caveman, brainstorming, qt-qml, qt-ui-design, ponytail.

## Steps
- [x] 0. Clone, memory read, roadmap read: S1-S5b merged; next = S5c (KI 8, 19a, 19b, 24a, 28b). S5d (measure) and S5e (TalkBack, themes, font scale, KI 26, KI 29) stay open.
- [x] 1. Findings from the code (before any design):
  - F-A: the app routes Android Back through Felgo `onBackButtonPressedGlobally` -> `Main.qml _handleBack()`, which closes the FIRST open entry of `_allDialogs()`. The picker sheet is not in that list. So KI 8's belief ("Back does nothing with a draft") is unproven AND the router can close `newOrderDlg` / `orderDetail` (parent) without the discard question.
  - F-B: `OrderDetailDialog` line controls (price field 64 + three 28 dp buttons) sit in the `ListCard` trailing slot; at 48 dp they need ~246 dp, which would crush the title on a 360 dp phone. They must move to their own row.
  - F-C: the cart steppers have no `Accessible.name` (TalkBack reads "unlabeled button").
- [ ] 2. Plan doc (decisions D1..), then code, tests, test plan, docs, skill.
- [ ] 3. Push; read CI; fix red.
- [ ] 4. Final report to Taher (done / open decisions / next = S5d, S5e).

## If this session is cut off
Resume at the first unticked step. Re-measure counts before claiming any: `cd functions && npm ci && node --test`, `node --test .github/scripts/__tests__/*.test.js`.
