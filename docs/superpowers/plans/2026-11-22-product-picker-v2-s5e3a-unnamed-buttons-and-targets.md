# Product picker v2, slice S5e-3a: name the icon-only buttons, finish KI 70 (a) and (b)

**Date:** 2026-11-22. **Branch:** `feat/2026-11-22-picker-s5e3-unnamed-buttons-targets`, cut from `main` @ `01c0ff5` (#214 S5e-2 merged). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-3a rows, checks 162 to 175). **Carried items:** KNOWN-ISSUES 97 (corrected and partly closed), 70 (a) and (b) (closed), new 107 to 111.

## 0. Where the roadmap stands (read from the repo and the GitHub API, 2026-11-22)
Picker v2: S1 to S5e-2 merged (#185 to #214). Open PRs: #212 (NO2, atomic-operations roadmap), #211 (docs), #178 (deps), #39, #29: none touches the picker. Left: **S5e-3 (this, split in two)**, S5e-4 (a curated device pass, KI 29 decided with a number). The owner says the device checks of every merged slice are done. No result is written in the repo (the test plan still says "not yet" for the S5e rows), so this plan treats every device-side open item (KI 103, 104, 106) as still open, and says so in section 6.

## 1. The fault (source only; no build, no device)
S5e-1 counted 8 unnamed buttons (KI 97) with a scan that treated any `text:` line in a block as a name. A ToolTip's `ToolTip.text:` is such a line, so two buttons in `MemberManagementDialog` were missed. A depth-aware scan (`testSupport/qmlButtonScan.js`, new) finds **10 icon-only buttons with no spoken name**: `FloatingActionButton` (3 instances: Inventory, Orders, Staff), the back buttons of Activity, Profile and Staff, the supplier "+" toggle of Add Product and of Restock, the rename toggle of Edit Product, the workspace edit toggle of Profile settings, and Suspend/Activate and Remove of Member management. TalkBack says "unlabeled button" on each; a ToolTip is hover only, so a phone never shows or speaks it.

A second class exists that the old scan could not see: about 20 buttons whose label lives only in a child `Text` (`contentItem: Text { text: ... }`) and whose own `text` is empty. Qt Quick Controls speaks the button's own `text`, so these are probably unlabeled too (UNVERIFIED: how Qt's Android bridge treats the child `Text` was not checked). Different fix, different decision (D1).

KI 70 (a): the "Manage channels ›" link in New Order is 28 dp tall. (b): the price and discount fields (New Order, Edit Order) are about 31 dp tall (a 6 dp pad each side of a 14 sp line).

## 2. Options and decisions (defaults taken, veto in the PR)
**S5e3a-D1. One slice or two?** S5e-3 as written holds four jobs: the 10 icon buttons, the ~20 text-child buttons, KI 70 (a) and (b), and a font-scale and two-theme pass. For one slice: the roadmap names them as one item. Against: the font and theme pass is a source audit whose findings may need design calls, and the text-child class needs an approach (D3) nobody has seen on a screen; one PR with all of it is long to review and long to resume on another account. **Taken: split. S5e-3a (this) = the 10 icon buttons + KI 70 (a) and (b) + a ratchet. S5e-3b = the text-child buttons + the font-scale and theme audit.**

**S5e3a-D2. How is an icon-only button named?** (a) `Accessible.role: Accessible.Button` + `Accessible.name: qsTr("...")` on each (the S5e-1 pattern, `BottomSheet`'s X); (b) turn on the ToolTip for touch; (c) give each button an own `text:` that the `contentItem` does not draw. For (a): one pattern in the repo, the sheet's tests already pin it, nothing visual changes. Against (a): a dynamic name (the + that becomes an x) needs two `qsTr` literals in a ternary (the rule says `qsTr` takes literals only). Against (b): hover does not exist on a phone. Against (c): `text` also feeds layout implicit sizes on some styles. **Taken: (a).**

**S5e3a-D3. The text-child class (S5e-3b) and the one link in this slice.** In this slice the "Manage channels" link gets its own `text: qsTr("Manage channels")` (the spoken name, no chevron) and its `contentItem` draws `text + "  ›"`. One `qsTr`, so name and picture cannot drift, and a screen reader does not read a decorative glyph. Alternative for all ~20: a `Accessible.name` copy of each label (two `qsTr` strings that must match, drift). **Taken: own `text` for this link now; the same recipe is the default for S5e-3b, veto there.**

**S5e3a-D4. FAB name.** `FloatingActionButton` has only an `iconName`, and "add" would be spoken as "add". It gets `property string label` and `Accessible.name: label`; each of the 3 instances passes a `qsTr` label (Add product, New order, Add staff). A fourth instance without a label would be silent again, so a ratchet pins the instance list and that each sets a label. Alternative: map the icon to a word inside the component (wrong word for the Staff one, which means two things). **Taken: label.**

**S5e3a-D5. Height of the four number fields.** Options: `Layout.preferredHeight: dp(48)` (fixed, clips the text at a big system font), `Layout.minimumHeight: dp(48)` (48 dp at normal font, grows when the font grows, the same trade as the S5e-1 chips), 44 (the SearchField's number, chosen there because five pages share the field; these four fields are in two dialogs only). **Taken: `minimumHeight: dp(48)` + `verticalAlignment: TextInput.AlignVCenter` set explicitly (the style's default is not read from a build). Cost: each price row is 4 to 8 dp taller; width is untouched, so the 320 dp fit is not made worse.** The "Manage channels" link goes 28 to 48 dp for the same reason (used once, no shared height); cost 20 dp of vertical space in a scrolling sheet.

**S5e3a-D6. Not resized here:** the back buttons (40 dp), the two Member buttons (32 dp), the workspace edit toggle (28 dp). They share a header slot or a card row sized by their width, and growing them changes a layout nobody has seen since a build. Written down (KNOWN-ISSUES 107), not changed. Names only.

**S5e3a-D7. Not named here:** the four number fields have no `Accessible.name` of their own (TalkBack hears the number and "edit box", the word "Price" is a separate stop). Same class as the buttons but a different control and a wording call ("Price of X"): KNOWN-ISSUES 108, S5e-3b.

## 3. Scope
In: the 10 buttons + `FloatingActionButton.label` (9 QML files + its 3 users), the "Manage channels" link, the four fields (`NewOrderDialog`, `OrderDetailDialog`). Tests: `functions/test/pickerS5e3Names.test.js`, `functions/test/testSupport/qmlButtonScan.js`. Out (written down, not done): the text-child buttons (KI 97 rest), unnamed fields (108), undersized icon buttons (107), the dead `qml/helper/OrderRow.qml` (no importer; its two 28 dp unnamed buttons are not counted, 109), font scale and themes (S5e-3b), KI 29, KI 103/104/106.

## 4. Tests (Node only; QML cannot load Felgo pages, so wiring is read and the name expressions are run)
`pickerS5e3Names.test.js` S5E3-01..: the scanner on hand-made snippets (strings and comments holding braces, one-line blocks, a root-defined button, nested blocks); a **ratchet**: zero icon-only unnamed raw buttons under `qml/` and the text-child list pinned (S5e-3b deletes entries); each of the 10 buttons wired with role and name, dynamic names run in a sandbox for both states and differ; the FAB label and its three instances; the link (48 dp, own text, no chevron in the name, handler kept); the four fields (min height 48, centred, padding kept, exact count per file); every added name is `qsTr` with a literal; a seeded random run (400 generated blocks) checks the scanner against its ground truth; regression: every touched handler is unchanged.

## 5. Lint
The repo's QML lint script is not in the tree (S5e-2 notes ran a local copy); rules applied by hand: only `Layout.*` on layout children, no `anchors` + `Layout` mix added, `qsTr` literals, no new `Item` wrappers, no function call in a hot binding.

## 6. Advice (the part Taher asked for)
1. **Write the device results down.** All 161 written checks say "not yet" in the test plan. If they were run, a pass/fail line per slice (even "all green except check N") takes two minutes and is the only way the next session can tell KI 103, 104 and 106 are still real. Without it S5e-4 cannot be curated.
2. **Do not widen S5e-3b into "all accessibility".** It has two honest jobs: the text-child buttons and the font and theme audit. A TalkBack live-announcement shim (KI 98, 106) is a C++ change with its own design; keep it out until someone is blocked by it.
3. **Three commit addresses are in use** (`taher.lkdw@gmail.com`, `lkdwtaher@gmail.com`, now `tsadmin@gmail.com`). This PR uses the one you gave this session. Pick one and put it in the project instructions.

## 7. Questions for Taher (none block the merge)
- **Q1.** Names in English only (the repo's `qsTr` has no translation files in use): fine to keep `qsTr` literals as the only i18n step? Default: yes.
- **Q2.** Should S5e-3b also resize the three undersized icon buttons (KI 107) once a build exists, even though it changes a header slot? Default: only after a device look.
- **Q3.** Is a 48 dp price field too tall for the New Order line row on your device? Checks 169 to 171 show it; revert is one property.

## 8. Result
(filled in at the end of the session)
