# Test plan — BottomSheet footer: the primary button keeps its label ("Stay signed in" showed as "S...")

**Branch:** `feat/2026-10-26-signout-guard` (PR #167, same PR on purpose). **Found:** on-device test of PR #167, 2026-10-28.
**Covers:** `qml/helper/SheetFooter.js` (new, pure), `qml/components/BottomSheet.qml` (footer: `TextMetrics`, `footerRow`, `primaryButton`, `_primaryFloor`), pins in `.github/scripts/__tests__/signOutGuardWiring.test.js`.
**No server change, no deploy. The app was not built or run in this session (standing rule).**

## Root cause (read from code, not guessed)
`PrimaryButton.contentItem` is an `Item` whose `Text` is anchored (`anchors.fill: parent`), so the button reports no implicit label width: its implicit width is its padding only (16 + 16 dp). `GhostButton.contentItem` is a plain `Text`, so its implicit width is the whole label. In the `BottomSheet` footer both buttons are `Layout.fillWidth` with no preferred width: the layout starts from those implicit widths and shares the spare room equally. Next to the long label "Sign out and discard" the primary button therefore started at about 32 dp and got half of the spare room (about 87 dp on a 360 dp phone) and elided "Stay signed in" to "S...". Sheets with a short secondary label ("Cancel") hid it; long primaries elsewhere ("Confirm & save", "Send reset link", "Import N rows") were exposed to the same fault.

## The change
`SheetFooter.primaryFloor(labelWidth, padding, rowWidth)` = `ceil(label) + padding + 2` (slack), capped at 65% of the row, 0 for no label or a row without width. `BottomSheet` measures the primary label with `TextMetrics` (same font as `PrimaryButton`'s text) and sets `Layout.minimumWidth` and `Layout.preferredWidth` of the primary button to that floor. The secondary (ghost) button gives way first; the primary keeps its label. Both buttons stay `fillWidth`, so spare room is still shared.
Alternatives weighed (Taher decides on the PR; this one is applied):
| Option | For | Against |
|---|---|---|
| A. Give `PrimaryButton` a real implicit width | Fixes every `PrimaryButton` in the app at the source | Touches every screen with a `PrimaryButton`, many are outside sheets with their own widths; no way to device-test all of them in one PR |
| B. Floor in the shared `BottomSheet` footer (applied) | Root cause fixed for all 14 two-button sheets, one place, one pure helper | The footer of all those sheets changes slightly (primary a bit wider next to a short Cancel), so they need a spot check |
| C. Opt-in property used only by `SignOutSheet` | Smallest blast radius | The same fault stays in the other sheets with long primaries |
| D. Stack the buttons vertically when both labels do not fit | Both labels always complete, also at Large font and in long translations | Different pattern, taller footer, more code; not what was asked |

## What was actually executed in the session (honest)
- **Node, not Qt.** The 21 test functions of `tests/tst_SheetFooter.qml` were run under a throw-away Node shim (not committed): **21/21**. `qmltestrunner` is CI-only.
- **Mutation check:** 25 hand mutants of `SheetFooter.js` (slack 0/1/3, cap 1/0.5/0.7, each branch of the number guard, empty-label shortcut, `ceil` vs `floor`/`round`/none, `min` vs `max`, each term of the sum, each guard on padding and row): **24/24 killable mutants killed**; the one survivor (`v > 0` -> `v >= 0`) is equivalent (0 maps to 0 either way).
- **Script suite:** `signOutGuardWiring.test.js` 43 -> **60/60** (17 new: 14 mutants, 3 edge/regression); whole `.github/scripts/__tests__/*.test.js` suite **169/169** (includes the skills-index test for Skill 139).
- **Not run:** `BottomSheet.qml` itself (Felgo, no `App` context under `qmltestrunner`: on-device only), the CI run of `tst_SheetFooter.qml`, anything on a device.

## 1. Unit tests (`tests/tst_SheetFooter.qml`, 21 functions)
| Kind | Cases |
|---|---|
| Constants | `SLACK` = 2, `MAX_SHARE` = 0.65 pinned to literals |
| Happy | label + padding + slack; fractional label rounds up; the real case (104 + 32 on a 312 row = 138, was about 87); roomier rows keep the same floor |
| Cap | cap applies for a long label; boundary (95 / 96 / 97); the secondary always keeps 35% of the row; narrowest layout (240 dp wide) |
| Negative | label: 0, negative, undefined, null, NaN, Infinity, string, object -> 0; row: 0, negative, NaN, undefined, Infinity, string -> 0; padding junk counts as 0; missing arguments do not throw |
| Edge | zero padding; tiny label; huge values stay finite; no state between calls |
| Regression | the reported bug at widths 320-480 dp with the real wording sizes |
| Scenario | twelve label widths: floor above the label or capped, monotonic |
| Monkey | seeded (20261028), 4000 random mixes incl. junk: number, finite, never negative, never above the cap, never above `need`, 0 when the row has no width; second monkey: monotonic in each argument |

## 2. Wiring (Node, CI "script tests")
`signOutGuardWiring.test.js`: import of the helper; `primaryFloor` fed by `primaryMetrics.advanceWidth`, the button's two paddings and `footerRow.width`; `Layout.minimumWidth` and `Layout.preferredWidth` both bound to `_primaryFloor` on the primary button; `footerRow` id; `TextMetrics` uses the SAME font expression and bold as `PrimaryButton`'s drawn text (changing one without the other goes red) and measures `primaryAction`; the helper is a `.pragma library` with the three-argument signature; comments do not satisfy a rule; a sheet without `TextMetrics` is reported, not thrown on; premise: `PrimaryButton` still anchors its text.

## 3. Regression (automated)
Existing suites unchanged and must stay green: `tst_SignOutGuard`, all 43 earlier wiring tests. No other test references `BottomSheet` footer geometry (grep of `tests/`, `test/`: none).

## 4. E2E
None. View-only change, nothing reaches the server.

## 5. Counts
Recount from the CI comment on PR #167 after the push; do not trust predictions. Expected delta: QML +23 (21 functions plus the runner's own `initTestCase` / `cleanupTestCase`), script tests +17.

---

## On-device test plan
**Prerequisites:** the PR #167 build; a phone of 360 dp width or narrower if you have one, and any larger phone; a NEW tenant (owner). To get the sign-out sheet: airplane mode, edit a product, Profile -> Sign out.

### Happy path
| # | Action | Expected |
|---|---|---|
| H1 | Sign-out sheet (see prerequisites) | **Stay signed in** is fully readable, no "...". "Sign out and discard" is smaller than before but still readable on a 390 dp or wider phone |
| H2 | Same on a 360 dp phone | "Stay signed in" complete. "Sign out and discard" complete or, at worst, ends in "..." after "disc" (known limit, see below) |
| H3 | Leave-workspace variant (non-owner member) | "Stay in workspace" complete next to "Leave and discard" |
| H4 | Tap Stay, then Sign out and discard | Both still work exactly as in the #167 plan (H3/H4 there) |

### Negative
| # | Action | Expected |
|---|---|---|
| N1 | Drain the queue while the sheet is open (E1 in the #167 plan) | Buttons become plain "Sign out" / "Stay signed in": both complete, the primary is not wider than needed |
| N2 | Android Back / tap outside / X | Stay signed in, as before |

### Edge cases
| # | Action | Expected |
|---|---|---|
| E1 | OS font size Large, 360 dp phone | The primary label is complete OR ends in "..." only when it is longer than 65% of the row; the secondary button is never pushed off the sheet; both buttons are fully on screen and tappable |
| E2 | Landscape, then back | Footer relayouts, no overlap |
| E3 | Another language (if available) with longer text | Same rule as E1 |
| E4 | Sheet open, rotate twice quickly | No warning spam in logcat ("Binding loop detected" / "QML RowLayout") |

### Footer spot check of every two-button BottomSheet (the floor is in the shared footer)
For each: open it, look at the footer, expect both labels complete, the primary not narrower than its label, nothing overlapping. FilterSheet (Apply / Reset), AnalysisFilterSheet (Apply / Reset), InviteMemberDialog (Send invite / Cancel), ProfileSettingsDialog (Save / Cancel), ConfirmReturnSheet (**Confirm & save** / Cancel), AddProductDialog (Save / Cancel), EditProductDialog (**Save changes** / Cancel), OrderDetailDialog (Save changes / Close), RestockDialog (Confirm / Cancel), AddStaffDialog (Save / Cancel), ImportPreviewDialog (**Import N rows** / Cancel, try N = 1, 9, 125), StaffDetailDialog (Save changes / Cancel), ForgotPasswordDialog (**Send reset link** / Cancel), NewOrderDialog (Place order / Cancel).
One-button sheets must be unchanged (Close / Done only, ghost button full width): StaffActionSheet, ExportSheet, ManageOrderChannelsDialog, StuckWritesSheet, MemberManagementDialog, ManageCategoriesDialog, NotificationsSheet.
Busy state: in a dialog that shows the spinner (Place order, Save), the label stays centred and complete while busy.

### Multi-scenario / monkey (manual)
Open and close five different sheets ten times each, rotating the phone now and then; change font size once in the middle. No crash, no clipped buttons, no layout warning in logcat.

### Known limit (open decision for Taher, Q-FW-1)
When both labels cannot fit side by side (about 340 dp wide or narrower, or Large font), the SECONDARY button ellipsizes first. For the sign-out sheet that can cut "Sign out and discard" to "Sign out and disc...". Option D above (stack the buttons vertically when they do not fit) removes it for good; it was not done because it changes the footer pattern, which was not asked for. Claude recommends D if a 340 dp phone is a target.

### Affected areas
| File | Automated coverage | Where to look on device |
|---|---|---|
| `qml/helper/SheetFooter.js` | 21 functions, 24/24 killable mutants | all rows |
| `qml/components/BottomSheet.qml` footer | static wiring pins only (Felgo) | H1-H4, E1-E4, the spot check |
| `qml/pages/SignOutSheet.qml` | unchanged | H1-H4, N1 |
