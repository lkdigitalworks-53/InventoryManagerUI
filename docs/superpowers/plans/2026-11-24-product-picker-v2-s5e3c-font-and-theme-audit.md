# Product picker v2, slice S5e-3c: font-scale and system-theme source audit

**Date:** 2026-11-24. **Branch:** `feat/2026-11-24-picker-s5e3c-font-and-theme-audit`, cut from `main` @ `a40e8c0` (#216 S5e-3b merged). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-3c rows, device checks 194 to 202). **Carried items:** KNOWN-ISSUES 29 (stays for S5e-4), new 135 to 138.

## 0. Where the roadmap stands (read from the repo, 2026-11-24)
Picker v2: S1 to S5e-3b merged (#185 to #216). Left: **S5e-3c (this)** and **S5e-4** (a curated device pass of about 20 checks, KI 29 decided with a number; that one is a phone job, not code). The owner says device checks of the merged slices are done; the repo still holds no written result (every S5e row says "not yet"), so device-side open items (KI 98, 103, 104, 106, 123, 127, 129, 130) are still treated as open.

## 1. What the audit measured (a script over every file of `qml/`, kept as `testSupport/qmlThemeScaleScan.js`)
| Question | Answer | Where it stands |
|---|---|---|
| `Text` / `Label` with no `color` | 3 of 347, all invisible: two are `visible: false` (toast width probe, login wordmark mask), one is a dead helper (`CardKPI`) | clean, pinned |
| Typed-text controls (`TextField`) with no `color` | 9 fields: **5 in the picker arc** (search box, 2 price and 2 discount boxes), 2 login fields, 2 already pinned | **5 fixed here**, login left (KI 142) |
| Bare pixel sizes (never follow the system font) | 25 of 378: 7 on the live photo sheet, 18 in five dead helpers | picker arc has none; rest pinned (KI 143) |
| Colour literals outside `Constants.qml` | 100 in 14 files; the picker arc has none | picker arc clean; rest pinned (KI 143) |
| Text tokens vs the four light surfaces | primary 17.85:1, secondary 7.58:1 on white; **muted 2.56:1** (fails WCAG AA 4.5) | token kept, pinned (KI 144) |
| Fixed-height rows holding unwrapped text, in the arc | 2 (the "In stock only" row, the "Manage channels" link), one line each, 48 dp | a device look, not a source defect (KI 145) |

## 2. Decisions (each has a default; veto in the PR)

**S5e3c-D1. Audit from source now, or wait for a build?** For waiting: only a phone at 2.0x shows what clips (S5e-3b advice 2). Against: the owner has finished the device passes and does not want a build run in a chat turn; the source scan is cheap, finds what a phone cannot be asked to find on all 60 files, and its ratchets keep the findings from growing. **Taken: source audit now; what it cannot prove goes to device checks 194 to 202.** Honest limit: this slice proves WIRING (a colour is set, a size goes through `sp()`), not what a screen looks like.

**S5e3c-D2. What does "both themes" mean here?** The roadmap line says "font scale and both themes". The app has ONE palette: `Constants.qml` is all light colours, the Profile "Appearance" row is a dead placeholder (KI 129), 344 of 347 `Text` set their own colour. So there is no dark theme to audit. The only way a system dark theme can reach the app is through what the app leaves to the Qt palette: the typed text and hint of a `TextField`, and the paint of a `Switch` or `SpinBox`. Whether Felgo's controls really follow the system dark scheme on a given Qt and Felgo version is **UNVERIFIED** (nothing in the repo forces a scheme). **Taken: treat it as a risk worth a one-line pin where the fill is a fixed light colour.** The pin costs nothing in a light theme and is the only protection if a phone is in dark mode.

**S5e3c-D3. Fix which fields?** The five of the picker arc (search box, the two New Order boxes, the two Edit Order boxes). Typed text `Constants.textPrimary` while enabled, `Constants.textMuted` while disabled (the same pair `AppComboBox` already uses; the boxes do disable while an order saves). Alternative: leave them and only record. Against: five lines, same pattern as the quantity box that already pins its colour, and a typed price that cannot be read is a robustness bug for money.

**S5e3c-D4. Search hint colour.** `placeholderTextColor: Constants.textSecondary` (7.58:1 on the white pill). `textMuted` would be softer and fails AA (2.56:1). This is the one change a user can SEE in a light theme (the hint is a little darker than the Basic default). **Taken: secondary, a11y over softness. Veto: say "soft" and it becomes `textMuted` with the AA failure written down.**

**S5e3c-D5. The two login fields (`AuthTextField`, `AuthPasswordField`): same defect, not fixed.** Not the picker arc, a different screen with its own tests. The fill is a fixed `#ffffff` so the risk is the same; it is also where an unreadable typed password hurts most. **Taken: not changed here (scope), pinned by `S5E3C-07` so fixing it forces the doc update, KI 142 with a recommendation: fix it next, two lines.** I am not hiding that I would do it first.

**S5e3c-D6. The 25 bare pixel sizes: delete, fix or leave?** 18 are in five helpers nobody uses (`CardKPI`, `OrderRow`, `PlaceholderPage`, `SegmentedNav`, `StatusBadge` via `OrderRow`). Fixing dead code is waste; deleting it is smaller. 7 are on the live photo sheet (Add and Edit Product), outside the picker. **Taken: neither here. KI 143 recommends one cleanup slice: delete the five dead helpers (with `OrderRow` and `SegmentedNav` tests, KI 121 and 128) and wrap the seven photo-sheet sizes in `sp()`.** Needs the owner to confirm the deletion.

**S5e3c-D7. The `textMuted` token is 2.56:1.** 42 uses in 23 files. Darkening it is a design call that changes every screen. **Taken: unchanged; ratchet `S5E3C-14` stops it spreading in the picker arc (2 uses today); KI 144.**

**S5e3c-D8. Not pinned: `Switch` (3 uses, paint only) and `SpinBox` (Restock quantity).** The sheet's switch is `Accessible.ignored` and `focusPolicy: Qt.NoFocus`, painted only; its track follows the palette (UNVERIFIED). The Restock `SpinBox` has the same typed-text risk as the five fields, in an inventory dialog. Both go to KI 142 and to device checks, not to code.

## 3. What changed
QML (3 files, 11 lines): `SearchField` (`color`, `placeholderTextColor`), `NewOrderDialog` (2 fields), `OrderDetailDialog` (2 fields). No size, anchor, handler, name or binding changed. Tests: `functions/test/pickerS5e3cAudit.test.js` (22 cases, S5E3C-01..22) and `functions/test/testSupport/qmlThemeScaleScan.js` (`scanColors`, `scanPixelSizes`, `scanHex`, `scanFixedHeightText`, `contrast`, `colorTokens`).

## 4. Test strategy
Node only (CI is the oracle, no Qt in the sandbox). `01..05` one per fixed field: the pinned expression, its own enabled flag, and WCAG contrast of the text token on the field's own fill token. `06` no uncoloured typed field in the arc, and the arc holds exactly 6 fields. `07..08, 10, 12, 14, 15` ratchets with the reason for every entry left (login fields, hidden or dead Text, bare sizes by file with a dead-code check, colour literals by file, `textMuted` count, two fixed-height rows). `09, 11, 13` invariants (arc has no bare size and no literal; `AvatarBadge._font` is `sp()` on all four branches; token contrast numbers). `16` regression (name, 48 dp, `sp()` font, number keyboard of the four fields survive). `17..22` the scanners: hand cases with decoys (comments, strings, nested child colour, `border.color`, a brace in a string), two seeded monkeys of 300 generated blocks each, a fixed-height hand test. Hand mutants: 17 (11 in QML, 6 in the scanner), all killed; two survived the first run (a no-op mutant of mine, and a raw-size check a `13 + extra` line now catches), one mutant had a wrong escape and was redone.

## 5. What is NOT done (written down)
- Login fields (KI 142), Restock `SpinBox` (KI 142), the three `Switch` paints (KI 142, UNVERIFIED).
- 25 bare pixel sizes and 100 colour literals outside `Constants.qml` (KI 143), the muted token (KI 144), two fixed-height rows (KI 145).
- Anything that needs a phone: checks 194 to 202. Not run.
- **S5e-4** (the curated 20-check device pass and KI 29 with a number) is not code and is not started.

## 6. Advice
1. **Fix the login fields next, before S5e-4.** Two lines, same test mechanism, and a login that cannot be read is the worst place for this.
2. **Run checks 194 and 201 first on a phone set to dark.** One minute each. If typed text was already readable there, the pins were insurance and KI 142 can drop its UNVERIFIED; if not, this slice just fixed a real bug.
3. **S5e-4 should be 20 checks, not 202.** Pick from: New Order, Edit Order, TalkBack through the sheet, 2.0x font, dark mode, KI 29 number. Write the result into the test plan, one line per check.

## 7. Questions for Taher (none block the merge)
- **Q1.** Search hint colour: `textSecondary` (taken) or the softer `textMuted` (fails AA)? Default: secondary.
- **Q2.** Fix the two login fields in the next slice? Default: yes.
- **Q3.** Delete the five dead helpers (KI 143)? Default: yes, own slice.
- **Q4.** Commit address (KI 125): this session used `dextran52@gmail.com` (owner instruction of 2026-11-24).

## 8. Result (2026-11-24)
New Node tests 22 (`S5E3C-01..22`). Functions suite 2352/2352 and scripts suite 1199/1199, both run by hand on this branch; `skills-index.js --check` current after Skill 189. Hand mutants 17, all killed (two survived the first run, see section 4). Not run: CI (read on the PR head), any device check (194 to 202), the repo's QML lint (not in the tree; rules applied by hand: no `anchors` + `Layout` mix, no new `Item`, no function call in a hot binding, no bare `pixelSize`).
