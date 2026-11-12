# Test plan — Atomic ops R5a: restock dialog (typed supplier joins the operation, field limits, wording)

Branch `feat/2026-11-10-r5a-restock-dialog-supplier-in-op`. Design: `docs/superpowers/specs/2026-11-10-r5a-restock-dialog-design.md`. Format: Skill 49.

## What was actually executed in the session (honest)
- **Review pass 3 (2026-11-11, PR #191 CI red):** RUN here: `functions/` suite 1421/1421 (1413 after the rebase, +8: `qmlReservedWords.guard.test.js` Q-1..Q-3 and `restockR5a.test.js` J-1..J-5), 4 of 4 hand mutants killed (joiners stripped again, joiners in the match key, joiner-only name accepted, unused text by `trim()`). NOT RUN here: both QML files below (CI). The QML job showed 2942 passed and 2 failed: `tst_RestockFlow` did not compile (`var long`) and `tst_InventoryStore_movementKinds` still expected a long reason to be cut. Both fixed.
- **Review pass 3, option A (Taher's choice):** RUN here: `functions/` suite 1434/1434 (K-1..K-7 in `restockR5a.test.js`, W-15..W-20 in `restockWire.test.js`, rig now has an outbox fed by the fake Gateway), `.github/scripts` 1049/1049, 7 of 7 hand mutants killed. NOT RUN here: the QML twins (6 functions in `tst_InventoryStore_movementKinds.qml`, CI only) and device steps 32 to 35.
- RUN (Node, this sandbox): `functions/` suite 1327/1327 (was 1290, +37 new in `restockR5a.test.js`), `.github/scripts` suite 905/905. 26 of 26 hand mutants killed (below).
- NOT RUN here (no Qt in the sandbox, standing rule): `tests/tst_RestockFlow.qml` (5 new test functions, 14 to 19), the whole dialog on a screen. CI is the QML oracle; Taher runs the on-device list.
- Rules and e2e: none. No rules, no server code and no collection changed. The server accepts the new request shape since R2 (proved here against the real `operationLogic`, E-1 to E-4).

## 1. Unit (Node, `functions/test/restockR5a.test.js`, and the QML twin)
| IDs | What |
|---|---|
| S-1..S-8 | `supplierFor` with `{ newName }`, `{ id }`, mixed, malformed, bad supplier lists; the string forms unchanged; name limit 100 (exactly 100 passes, 101 refused, measured trimmed); `SUP-Foo` as a name vs as an id |
| P-1..P-3 | `partyFor` (typed name wins; index 0, negative, fractional, NaN, past the end, non-string entries are "no supplier"); `newPartyChoice` (none, invalid, existing with canonical name, new) |
| L-1..L-7 | reason 500/501 and trimmed; cost exactly 1e9, 1e9+1, 1e300, NaN fallback, Infinity left to the planner; every refusal reason has its own text and the texts differ; limit texts name the limit; reason limit equals the server's `MAX_REASON` and `StockMovements.MAX_REASON`; a 500-character reason is whole in the ledger row, the batch note and the purchase row; qty 9999 times the cost ceiling stays finite |

## 2. Functional (Node, real function bodies and the real server code)
| IDs | What |
|---|---|
| E-1 | typed new supplier -> `partyFor` -> `makeInput` -> `RestockPlan.build` -> real `applyOperation`: minted `SUP-` id, supplier doc named as typed, batch and purchase carry it, stock 10 -> 15 |
| E-2 | a new name starting with `SUP-` becomes a real supplier (not a dangling id) |
| E-3 | THE defect, closed: the product vanished, the operation is refused (404), the store is byte-identical afterwards: no supplier, counter untouched, no marker |
| E-4 | same key twice: one supplier, same ids in the replayed answer |
| D-1..D-4 | the real `_useTypedParty` body in a `vm`: new name held and nothing created; known name picks that row; empty text does nothing; over-long name toasts and changes nothing |
| D-5..D-8 | the real `_confirm` body: a pending name is sent as `{ newName }`, otherwise the picked id or ""; the whole tap through plan and real server ends as a supplier named as typed; a supplier that arrived meanwhile is matched, not duplicated |

## 3. Rules / E2E
None (see above). The existing emulator case for restock (R4) exercises the same operation shape and is unchanged.

## 4. Regression (automated)
G-1..G-6 read the dialog and `AuthTextField` text: no `SupplierStore.addSupplier*` and no `Gateway.` call left in the dialog; the "Save" label that saved a supplier is gone; "Use" runs `_useTypedParty` and no second inline copy exists; the combo clears the pending name on a user pick and shows it otherwise; `openFor` resets it; both fields take `maximumLength` from the helper's constants and `AuthTextField` forwards it; the hint text exists. Adjusted existing guards: CF-17 (free names of `_confirm`), RD-2 (the dialog may now read `RestockFlow.MAX_*`, so the guard accepts `var` exports; a missing constant would silently be `undefined`), F-9 and E-3 of `restockFlow.test.js` (new limits; the planner's `too-large` is still reached, now through a huge product name).

## 5. Monkey and multi-scenario
M-1: 600 seeded random dialog states (typed names incl. blank, `SUP-`, `{{sup}}`, 101 characters, non-strings; random picker index incl. out of range; costs incl. NaN, 1e9, 1e308, Infinity; reasons incl. 501 characters and `{{batch}}`; quantities incl. 0). Never throws; every refusal has a known reason and a text; every plan the app builds is ACCEPTED by the real server validator; the run must reach both outcomes (planned > 50 and refused > 50).

## 6. Hand mutants (26, all killed; script kept in the session, list here)
M1 object party ignored; M2 blank `newName` accepted; M3 name limit off by one; M4 case-sensitive match; M5 string `SUP-` no longer an id; M6 typed name ignored; M7 index 0 read as a row; M8 index without a string behind it; M9 empty text not "none"; M10 existing treated as new; M11 reason measured untrimmed; M12 reason off by one; M13 cost ceiling off by one; M14 `Infinity` becomes "too large"; M15 reason limit drifts from the server; M16 reason text missing; M17 cost text duplicates another; M18 "Use" button dead; M19 a pick does not clear the name; M20 `openFor` keeps the old name; M21 reason field unlimited; M22 name field unlimited; M23 Confirm sends no party; M24 combo not reset on a new name; M25 an existing match keeps a stale pending name; M26 `AuthTextField` drops `maximumLength`. First run: 3 survived (M7 and M8 were an equivalent guard, which was removed as redundant code; M17 needed a wording assertion); all killed after that.

## 7. Counts
Functions 1290 -> 1327 (+37), 1343 after the PR #191 sweep (+16). Scripts 905 (unchanged). QML: `tst_RestockFlow` 14 -> 19 test functions in the first commit, 24 after the PR #191 sweep, and `tst_RestockPlan` 25 -> 26 (CI to confirm the totals). Coverage statement: the changed pure helper (`RestockFlow.js` new code: `supplierFor`, `partyFor`, `newPartyChoice`, `makeInput` limits, `refusalText`) is covered line and branch by the cases above (each new branch has a case and a killing mutant). The dialog QML (`_useTypedParty`, `_confirm`, bindings) is covered by its real function bodies in Node plus the on-device list below; the bindings (`displayText`, `visible`, `maximumLength`) are pinned by source guards only. Review pass 3: functions 1343 -> 1413 after the rebase onto main -> 1421 (+8). QML: `tst_RestockFlow` 24 -> 27 test functions (engine has `String.normalize`, joiners, unused text of invisible characters) and `tst_InventoryStore_movementKinds` 1 test replaced by 4 (CI to confirm the totals).

## 8. PR #191 review sweep (added on the same branch)
Findings fixed here, each with its tests (Node RUN: functions 1327 -> 1343, +16 in `restockR5a.test.js`; QML twin `tst_RestockFlow` 14 -> 24 test functions and `tst_RestockPlan` 25 -> 26, CI only). The sweep was done by hand in two rounds (no sub-agents, per Taher): round 1 F-A..F-E, round 2 F-F..F-I, found by running probes through the real planner and server.
| ID | Finding (concrete case) | Fix | Tests |
|---|---|---|---|
| F-A | `costFromText` used `Number()`: "0x10" booked 16, "0b11" 3, "0o7" 7, "1e3" 1000, with no refusal | only a plain decimal is a cost; the rest is -1 (refused as bad-cost) | C-1, C-2 (2000-string monkey), D2-1 adjusted ("1e2" moved to the junk list), QML twin |
| F-B | A known supplier whose name is over 100 characters (legacy or imported) was refused "supplier-too-long" by the string path, forcing a duplicate | match a known name first, enforce the limit only on a NEW name | S-9, QML twin |
| F-C | A name typed in the new-supplier row but never sent with "Use" was silently dropped at Confirm (restock booked with no supplier) | Confirm refuses with a message, before busy and before anything is read | U-1..U-4, G-7, CF-17 and the two Confirm rigs adjusted |
| F-D | The "After this, stock will be" line read the committed `value` while Confirm books the typed text (type 25, no Enter: line says +10, Confirm books +25) | the line reads `RestockFlow.qtyFromField(qtyField)`, and shows the refusal text when the text cannot be booked | G-7 (source guard); binding itself on device (step 22) |
| F-E | Reopening the sheet after typing a quantity and cancelling left the typed text in the SpinBox (assigning the same `value` 10 does not rewrite it), and Confirm booked it | `openFor` moves the value to `from` first, then to 10 | G-7; on device (step 23) |
| F-F | A supplier name made only of zero-width characters (U+200B..U+200D, U+2060, U+FEFF) passed as a name: a supplier nobody can see | `_cleanName` removes them; a name empty after cleaning is `bad-supplier` | N-2, QML twin |
| F-G | "Cafe" + combining accent (another keyboard, a paste) did not match "Café" and made a second supplier; a pasted tab or newline was stored in the name; double spaces broke the match | one spelling for storing AND comparing: NFC, zero-width removed, whitespace runs folded, trimmed (`normalize` guarded) | N-1, N-3, N-4, N-7 (1500-string monkey: result is a refusal or a fixed point), QML twin |
| F-H | A typed "-0" produced a negative zero cost | `costFromText` returns a plain 0 | N-5, QML twin |
| F-I | The purchase `total` carried float noise: 3 x 0.1 stored as 0.30000000000000004, 3 x 0.123456789 as 0.3703703673703703 (the order totals are rounded to 2 places, the purchase was not) | `RestockPlan._money`: 2 places; a huge value is kept whole because `x * 100` would overflow to Infinity (JSON null); the unit cost keeps what was typed | N-6 (real server stores the rounded total), N-8, mutants, `tst_RestockPlan` twin |
| F-J | Review pass 3: U+200C and U+200D were stripped from a stored name, so a Hindi conjunct or a Persian name lost its joiner and was displayed wrong | only U+200B, U+2060, U+FEFF are stripped; the joiners are left out of the match key only; a joiner-only name is still blank; the unused-text check uses the same key | J-1..J-5, N-2, N-7 (alphabet now has the joiners), QML twin |
| F-K | Review pass 3 (CI): `tst_RestockFlow.qml` used `var long`, a reserved word in QML's JavaScript, so the file did not compile and none of its tests ran | renamed; `qmlReservedWords.guard.test.js` reads every QML and helper file in the Node job | Q-1..Q-3 (the guard failed on exactly that line before the rename, nowhere else) |
| F-L | Review pass 3 (CI): `tst_InventoryStore_movementKinds` expected a 900-character reason to be cut to 500 and queued; since R5a it is refused | replaced by: refused over 500 (nothing queued, no mint), 500 whole, 500 plus padding, 501 refused | QML only (CI) |
| F-M | Review pass 3, Taher chose option A: two offline restocks with the same NEW supplier created two suppliers | a restock whose new supplier name matches a `create supplier` op in a still-queued restock is refused with a message; known supplier, other new name, no supplier are not held; the hold ends when the first item leaves the queue (synced or discarded) | `restockR5a.test.js` K-1..K-7, `restockWire.test.js` W-15..W-20, `tst_InventoryStore_movementKinds.qml` (6 functions, CI) |
Hand mutants for the sweep code: 16 of 16 killed (round 1: regex loosened, length check before the known match, unused text never reported, Confirm without the check, label reading `value`, no value cycle; round 2: no NFC, no zero-width strip, no whitespace fold, known side not cleaned, string path not cleaned, `-0` kept, total unrounded, unit cost rounded too, overflow guard removed). One round-2 mutant first did not apply (shell quoting) and was rerun from a script file.
Checked by hand and found sound: the stock line binding re-evaluates as the SpinBox TEXT changes (`contentItem.text` is a notifying property read inside the helper); `openFor` moving `value` away and back rewrites the text; picking any row, the placeholder included, clears the pending name (`activated` fires on a user pick); Confirm paths set `busy` only after every refusal; the unused-name refusal comes before `busy`.
Not fixed, on purpose: a reason or supplier name is measured in UTF-16 units (an emoji counts 2), the same unit as Qt's `maximumLength` and the server's slice, so the texts say "characters" for a slightly different count; the "{{sup}}" refusal text says "the text" without naming the field (practically unreachable, design T7); a pasted text longer than a `maximumLength` is cut silently by Qt; two offline devices typing one new name (O1). The QML linter's repo-wide findings (`var`, `id: dlg`, attribute order) are the codebase convention and unchanged.

## 9. PR #191 review pass 4: Android launch crash (added on the same branch)
Taher reported the Felgo Cloud build exits at launch on a clean install. Static review of the files the app loads at startup found one definite load error, introduced by this PR:

| ID | Finding (concrete case) | Fix | Tests |
|---|---|---|---|
| F-N | `AuthTextField.qml` declared `property alias maxLength: input.maxLength`. `input` is a `QQC.TextField`; QML has no `maxLength` (that is QLineEdit), the property is `maximumLength`. An alias to a missing property is a compile error, so `AuthTextField.qml` did not load, and neither did `LoginPage.qml` (it uses the type) or `Main.qml` (it instantiates `LoginPage` at the root). Qt then exits at once, which looks like a crash. Nothing in CI could see it: Felgo components cannot be loaded by `qmltestrunner`, and `restockR5a.test.js` G-5 pinned the wrong name. | alias renamed to `maximumLength: input.maximumLength`; the two users in `RestockDialog.qml` renamed; G-5 pinned to the real name | G-5, `qmlAliasTargets.guard.test.js` AS-1..AS-6, AL-0..AL-3, IM-1 (11 tests; AL-1, AL-2, AL-3 and G-5 fail on the broken tree, pass on the fix) |

Also checked, found sound: all 235 `import "..."` paths in `qml/` resolve with exact letter case (IM-1 keeps it so; Android is case-sensitive, Windows and macOS are not); no JS `.import` cycle; no `.pragma library` file imports a non-library file; no JS API newer than the Qt 6 engine in `qml/` (`normalize` and `Intl` are guarded); all other 23 aliases target real properties; every property assigned on a local component exists on it; every type, singleton and `BottomSheet` property that `RestockDialog.qml` uses exists.
Same load-error class could still hide elsewhere: `maximumLength` on a `QQC.TextField` is used by `ProductPickerRow.qml` (first loaded by a device in PR #194, which wired the picker into `NewOrderDialog`). It is a real property; the file is listed as a device check below because no test can load it.
Not fixed, on purpose: there is still no automated load of any Felgo component. The guards read text. A real load test would need Felgo in CI.
Counts (observed here, `node --test test/*.test.js`): 1182 tests, 1173 pass; 9 files fail on `Cannot find module 'node-mocks-http'` (dependencies not installed in this sandbox, same result on the clean tree, CI has them). New: 11 tests in `qmlAliasTargets.guard.test.js`; G-5 changed. Proof the guard bites: with the QML fix stashed, AL-1, AL-2, AL-3 and G-5 fail (4 of 4); with the fix, 11 of 11 pass.

# On-device test plan (Taher, needs a build of this branch)

Prerequisites. P1: signed in as owner or admin of a clean test workspace. P2: at least two products (A with stock 10, B with stock 4) and two suppliers ("Acme Farms", "Bolt & Co"). P3: a second device or a Firestore console for the checks marked (console). P4: airplane mode available.

### Happy path
1. Open Restock on A. Tap the "+" next to Supplier. Type "Newco" in the new row, tap **Use**. EXPECT: the row closes; the combo reads "New: Newco"; the hint says "Newco will be added as a new supplier when you confirm this restock"; the Suppliers screen (open it from another tab only after step 3) does NOT list Newco yet.
2. Quantity 5, cost left as shown, reason "test". Tap **Confirm**. EXPECT: busy card, then "Restocked +5 units", sheet closes.
3. Open Suppliers. EXPECT: "Newco" is there exactly once. Open A's batches: one new batch whose supplier is Newco. A's stock is 15. (console) the `suppliers` doc has the minted id and the batch/purchase docs carry it.
4. Restock B choosing "Acme Farms" in the picker. EXPECT: unchanged behaviour: stock +N, batch supplier Acme Farms, no new supplier.
5. Restock A again, type "newco" (lower case) and **Use**. EXPECT: the combo picks the existing "Newco" row (no "New:" label, no hint). Confirm. EXPECT: still ONE Newco in Suppliers.

### Negative
6. THE bug (P1): Restock A, **Use** with "Ghost Ltd", then **Cancel** the sheet. EXPECT: no "Ghost Ltd" in Suppliers (before this change it was there).
7. Restock A, **Use** "Ghost Two", then in the console delete product A, tap Confirm. EXPECT: a refusal text that says the product is gone and nothing was added; no "Ghost Two" in Suppliers; (console) `counters/suppliers` value unchanged.
8. In the new-supplier row paste 150 characters. EXPECT: it stops at 100.
9. In Reason paste 600 characters. EXPECT: it stops at 500.
10. Unit cost "99999999999" (11 digits), Confirm. EXPECT: "Unit cost is too large. Enter the price of ONE unit, up to 1000000000", nothing sent, sheet still open and usable.
11. Unit cost "abc", Confirm. EXPECT: "Unit cost is not a valid amount" (unchanged).

### Edge cases
12. **Use** "SUP-Foo" (a name that looks like an id), Confirm. EXPECT: a new supplier named "SUP-Foo" with a normal minted id; the batch shows supplier "SUP-Foo", not a blank.
13. **Use** "  Acme   " (padding, and only part of "Acme Farms"), Confirm. EXPECT: a NEW supplier "Acme" (only the whole name matches, ignoring case and padding; there is no fuzzy match). Check you are happy with that.
14. **Use** with the field empty. EXPECT: nothing happens, row stays open.
15. Type a new name, **Use**, then pick "Bolt & Co" in the combo. EXPECT: "New:" label and hint disappear; Confirm books Bolt & Co and creates no supplier.
16. **Use** "Newco2", close the sheet with Cancel, open Restock again. EXPECT: the combo is back to the placeholder, no hint.
17. Open Restock, tap "+", type text, tap the "x" (close row) without **Use**. EXPECT: the typed text is discarded and no supplier is chosen.

### PR #191 sweep steps
22. Open Restock on A. Type 25 in Add quantity, do NOT press Enter, look at the line under it, then tap Confirm. EXPECT: the line reads "After this, stock will be <stock + 25> units", and Confirm books +25 (the same number).
23. Type 25 in Add quantity (no Enter), Cancel, open Restock again on the same product. EXPECT: the field shows 10 again.
24. Type "abc" in Add quantity. EXPECT: the line under it reads "Enter a whole quantity from 1 to 9999"; Confirm shows the same text and sends nothing.
25. Tap "+", type "Half Typed" in the new-supplier row and tap Confirm WITHOUT "Use". EXPECT: toast "You typed a new supplier name. Tap Use to add it, or clear the field"; nothing is sent; the sheet stays open and usable. Tap Use, then Confirm: books as in step 2.
26. Unit cost "0x10" or "1e3", Confirm. EXPECT: "Unit cost is not a valid amount" and nothing sent. "12.5", "5." and ".5" are accepted.
27. Use "Café" typed with a combining accent (or paste one), where "Café" already exists. EXPECT: the existing row is picked, no second supplier. Use "A   B" with extra spaces: the hint shows "A B". Use a name of only spaces or pasted zero-width characters: nothing is added.
28. Restock 3 units at cost 0.1. EXPECT: the purchase row total is 0.30 (check in Transactions or the console: `total` 0.3, `unitCost` 0.1).
29. Use a Hindi name typed with a joiner (for example the conjunct in "kshatriya" typed as the Devanagari letters ka, virama, ZWJ, ssa, on a Hindi keyboard or pasted), or a Persian name with a half-space. Confirm. EXPECT: the supplier appears in Suppliers drawn with the joined form (not split into separate letters), once. Type the same name again without the joiner on a second restock. EXPECT: the existing supplier is picked, no second one.
30. Paste exactly 500 characters into Reason, Confirm. EXPECT: accepted. Paste 501 (Qt cuts a paste at the field limit silently, so you will see 500). EXPECT: the field never holds more than 500, and the batch note, the purchase row and the ledger row all carry the same text.
31. Open Restock, tap "+", paste only an invisible character (a zero-width space) into the new-supplier field, then Confirm without tapping Use. EXPECT: no message about a name you never typed, the restock books with no supplier. Tap Use instead. EXPECT: "Supplier name is not valid".
32. Airplane mode. Restock product A with a NEW supplier "Acme" (tap "+", type, Use, Confirm). EXPECT: saved, queued. Restock product B and type "  acme " as a new supplier, Use, Confirm. EXPECT: refused with "A restock that adds the supplier ... is still waiting to sync", nothing queued for B, stock of B unchanged.
33. Same state: restock product C with no supplier, product D with a supplier that already exists in the list, product E with a different new name. EXPECT: all three queued, no refusal.
34. Go online and wait for the sync. Restock product B again with "Acme". EXPECT: accepted, and Suppliers shows ONE "Acme" (the second restock used the supplier the first created).
35. Airplane mode again: queue product A with new supplier "Beta", open the queue and discard that restock, then restock B with "Beta". EXPECT: accepted (the hold ended with the item).
36. (Pass 4, do this FIRST) Uninstall the app, install the new Felgo Cloud build, open it. EXPECT: the Login page appears (no exit at launch). Type in the email and password fields. Sign in, open Restock: the Reason field stops at 500 characters and the new-supplier name at 100.
37. (Pass 4) With the same build, open New Order, tap "Add products". EXPECT: the product sheet opens with rows, search, steppers (it was first wired into a startup page in PR #194 and has not been loaded on a device before; a failure here is not this PR).

### Multiple scenarios
18. Airplane mode. Restock A with **Use** "Offline Co". Confirm. EXPECT: "Restock saved. Stock updates when it syncs", A hidden from the New Order picker. Turn the network on. EXPECT: after sync "Offline Co" exists once, A's stock is up, A selectable again.
19. Two devices: device 1 types new "Dual Co" and Confirms while offline; device 2 creates "Dual Co" through the Suppliers screen; device 1 goes online. EXPECT: two suppliers named "Dual Co" (known limit O1, the server does not dedupe by name). Record, do not fail the slice.
20. Kill the app after an offline Confirm with a new supplier, relaunch, go online. EXPECT: applied exactly once, one supplier.

### Monkey (manual, 2 minutes)
21. Hammer **Use** with random text (emoji, "{{sup}}", "{{batch}}", spaces, 99/100/101 characters), flip the picker, tap "+" and "x", Confirm and Cancel at random. EXPECT: no crash, no stuck busy card, no unexpected supplier in Suppliers (only ones whose restock was confirmed). "{{sup}}" as the NAME: EXPECT the refusal "Remove any {{ or }} from the text and try again".

### Affected areas (spot check, 1 minute each)
Add Product dialog (its own inline "add new party" is unchanged and still creates the supplier immediately: known, separate slice); Supplier list; other screens using `AuthTextField` (login, profile, add staff): typing unchanged, no new length cap; Notifications/Activity entry for a restock still appears (still written by the client, R5b moves it).
