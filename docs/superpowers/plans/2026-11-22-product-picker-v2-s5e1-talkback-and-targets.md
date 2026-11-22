# Product picker v2, slice S5e-1: the sheet's controls speak and are big enough to hit

**Date:** 2026-11-22. **Branch:** `feat/2026-11-22-picker-s5e1-talkback-and-targets`, cut from `main` @ `ae81334` (#210 S5d merged).
**Design:** `specs/2026-11-03-product-picker-v2-design.md` and `specs/2026-11-03-product-picker-v2-audit-and-decisions.md` (touch targets at least 48 dp, TalkBack, both themes, largest font). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-1 rows, checks 141 to 150). **Carried items touched:** KNOWN-ISSUES 70 (c) and the S5e item "TalkBack of the whole sheet" (first part); new 94 to 99.

## 0. Where the roadmap stands (read from the repo, 2026-11-22)
S1 to S5d are merged (#185, #187, #194, #196, #200, #202, #206, #210). Left in the picker roadmap: **S5e** = TalkBack of the whole sheet, themes, font scale, ToastHost wrap (KI 26, its own PR), small touch targets (KI 70), KI 29 cap, final device pass. Open PRs are #211 (docs), #178 (deps), #39, #29: none touches the picker. The other roadmap, atomic operations, is at step 3 (NO1 server merged, NO2 client planner next, waiting on Q-NO-1); it is NOT this slice (section 7).

## 1. What the audit found (source only; no build, no device)
Read `ProductPickerSheet`, `ProductPickerRow`, `CartStepper`, `ChipScroller`, `SearchField`, `BottomSheet`, `GhostButton`, `PrimaryButton`. What S2 and S5c already did stays: the in-stock row (one stop, checkbox, press and toggle actions, the switch ignored), the stepper buttons (named, 48 dp), the quantity field (named with unit), the footer buttons (a `QQC.Button` takes its name from its text). What was missing:

| # | Control | Fault | Evidence |
|---|---|---|---|
| A1 | Category chips (`ChipScroller`, shared) | A bare `Rectangle` plus `MouseArea`: no role, no name, no action; the painted text is exposed as plain text, so TalkBack can read a chip but has no action on it. Touch target = the 32 dp pill inside a 40 dp row | no `Accessible` in the file |
| A2 | Search clear button (`SearchField`, shared) | `AbstractButton` with no name ("unlabeled button"), 28 dp | no `Accessible` in the file |
| A3 | Sheet close X (`BottomSheet`, shared by every sheet) | no name, 36 dp | no `Accessible` in the file |
| A4 | Row name | `name, ID, pill, in order, reason`: the price and the picked quantity were missing, though the test plan (check 25) says the row reads "name, ID, price, availability and quantity" | `ProductPickerRow.qml` |
| A5 | Search text field | no explicit name | `SearchField.qml` |
| A6 | Everything else in the app | 8 more `AbstractButton` blocks with no name (list in KNOWN-ISSUES 97) | script in KNOWN-ISSUES 97 |

## 2. Why this is a slice and not the whole of S5e
S5e as written is five unrelated things, three of which need a screen. The cut, each piece merges alone:

| Slice | Content | Needs a device or a decision |
|---|---|---|
| **S5e-1 (this PR)** | A1 to A5: names, roles, actions, 44 to 48 dp targets on the sheet's own controls and the three shared components it reuses | device checks 141 to 150 afterwards |
| S5e-2 | ToastHost wrap (KI 26): its own PR as KI 26 says, with a device check | device |
| S5e-3 | Font scale and both themes pass over the sheet and the two order dialogs; the other unnamed buttons (KI 97); KI 70 (a) and (b) (the 28 dp "Manage channels" link, the 31 dp price fields) | device first |
| S5e-4 | A curated final device pass (see Advice, section 6) and KI 29 decided with a number | device, Taher |

KI 29 (cap on a completed-order edit) stays "measure first" (decided 2026-11-15, Q3): no code in any S5e slice until check 82 gives a number.

## 3. Decisions (defaults taken, veto in the PR)
**S5e1-D1. Change the three shared components in place, or give the picker its own copies?** For in place: the same faults sit on every screen that uses them, an opt-in flag leaves the rest of the app unlabeled and the two versions drift; the changes are names, roles and hit areas, not looks. Against: the blast radius is wide (four pages use `ChipScroller`, five use `SearchField`, every sheet uses `BottomSheet`) and nobody has seen it on a screen; a mistake in a shared component is a mistake everywhere. Mitigation: S5E1-07 pins that no page sets a height on its chips and lists every consumer (a new one fails the test until looked at); S5E1-09 pins that the sheet header keeps the 36 dp it lays out. **Taken: in place.**

**S5e1-D2. Chip role.** Options: `RadioButton` with `checked` (a chip row is single select), or `Button` with a selected state. Qt's `Accessible.selected` is a list-item idea; `RadioButton` plus `checked` is the pair the in-stock row already uses for its own role. Against: if Android reads "radio button" oddly for a filter, the word is wrong but the action works. **Taken: `RadioButton`, device check 143.**

**S5e1-D3. Chip row height 40 to 48 for all five users?** Options: (a) keep 40 and extend the hit area (impossible: the row's `Flickable` clips at its height), (b) a `touchHeight` opt-in per page, (c) 48 for everyone. For (c): one rule, no per-page forks, 48 is what the design and Android guidelines say. Against (c): every chip row in the app gets 8 dp taller and the layouts below shift; all five users set only `Layout.fillWidth` and no height (pinned), so nothing is forced to a size, but it is unseen. The row also GROWS with the pill at a big system font (`_pillHeight` measured with a `TextMetrics` on the chip's own font; first draft used a fixed 48 dp and would have clipped at iOS accessibility text sizes, found while writing KNOWN-ISSUES). **Taken: (c), device check 145.**

**S5e1-D4. Where do the row's words live?** In `qml/helper/PickerSpeech.js` (pure, tested in Node and as a derived QML twin), not as string glue in the delegate: the order of parts, the dedup and the junk rules have right and wrong answers (Skill 83). The price arrives already formatted (the helper knows no store). Against: one more helper file for a sentence. For: the same sentence glued in QML cannot be tested at all. **Taken: helper.**

**S5e1-D5. What does the row say about price?** The model gives `price: 0` for "no selling price" AND for a free item (`PickerSheetModel.priceOf`). Saying "0.00 per pcs" for a product that has NO price would be a false statement (KI 43). So: a price is spoken only when above zero; a free item is not announced as free (KI 94). Alternative: add a `priceKnown` role to every row (touches the exact-key-list tests of the model and its twin, and the delegate's `required property` list) for a case that is rare and harmless (a free item is still added at no charge, and the totals say 0). **Taken: speak only above zero, KI 94.**

**S5e1-D6. Quantity in the row name.** The quantity field has its own stop ("Quantity of X, in kg", value read as the text). The row name adds "3 selected" only when above zero, and "Maximum reached" at the ceiling, so a swipe over the row says where it stands. Possible double reading (row name plus the children) is a device question (KI 95, check 142), not guessable from source.

**S5e1-D7. Clear-search button 44 dp, not 48.** The field is 44 dp high and shared by five pages; a 48 dp button would make the field taller everywhere. The button is as tall as the field (44) and 44 wide. Cost: 4 dp under the guideline. **Taken: 44, stated.**

**S5e1-D8. Sheet X: 48 dp without growing the header.** The wrapper keeps the 36 dp the header lays out; the 48 dp button is centred on it and reaches 6 dp past it into free margin (the body starts 8 dp below). Against: a hit area that overflows its parent is unusual QML and its delivery on a phone is not seen; if Android does not deliver a touch outside the wrapper, the X is a 36 dp target as before and nothing is lost. **Taken, device check 148.**

## 4. Scope
In: `PickerSpeech.js` (new); `ProductPickerRow` name binding; `ChipScroller`; `SearchField`; `BottomSheet` X. Out (written down, not done): the other unnamed buttons (KI 97), live announcements of totals (KI 98), free item announced (KI 94), ToastHost (S5e-2), font and themes pass (S5e-3), KI 70 (a) and (b), KI 29.

## 5. Tests
- `functions/test/pickerSpeech.test.js` SPK-01..12 (`SPK-12` is Node only: it builds real rows with `PickerSheetModel.build` and proves the speech reads the keys the model really gives, and a no-price row never says a price). Derived QML twin `tests/tst_PickerSpeech.qml` (registered in `pickerTwin.js`, `PAIR-01`).
- `functions/test/pickerS5e1Wiring.test.js` S5E1-01..12: the row's name binding is run against a row double; `chip.spoken` and `chip.choose` are run in a sandbox; the three shared components are pinned; every `AbstractButton` in the sheet's surface must name itself; every `ChipScroller` consumer is listed.
- Seeded monkey (SPK-11, 600 rounds of junk in every field). Hand mutants: 30, all killed (labels in section 8).
- Not covered and said so: how TalkBack reads any of it (device), the overflow hit area of the X (device), the chip row's look at five pages (device). CI runs the derived twin.

## 6. Advice (the part Taher asked for)
1. **Build the app once before more layout slices.** S5c changed the cart rows, S5e-1 changes three shared controls, nothing since S4 has been seen on a screen. 150 device checks are written and none of S5c to S5e-1 has been run. The cheapest risk reduction in the whole roadmap is one device pass of checks 120 to 150, not another slice. Prune before running: section "S5e-4" below.
2. **Do not extend the device plan forever.** It has 150 checks. S5e-4 should be a curated 20-check smoke pass (one New Order, one Edit Order, TalkBack through the sheet, largest font, dark theme), not the sum of every slice.
3. **The atomic-operations roadmap is waiting on you,** not on code: Q-NO-1 (risky stock paths before NO2/NO3?) has been open since 2026-11-21. I picked the picker S5e because #210 merged and you named it; NO2 is the next unblocked work there once you answer.

## 7. Questions for Taher (none block the merge)
- **Q1.** Chip rows 8 dp taller on five screens (D3): accept, or keep 40 and give up the 48 dp target for chips? Recommendation: accept; this is a primary filter control.
- **Q2.** Is a TalkBack pass over the app's 8 other unnamed buttons (KI 97) worth a slice before the device pass? Two of them are in the Add Product and Restock sheets, which the atomic arc touches anyway. Recommendation: fold them into S5e-3, do not widen this PR.
- **Q3.** A free item (price 0) is not spoken as free (KI 94). Acceptable? Recommendation: yes until someone sells free items.
- **Q4.** Commit email (KI 93): the history now carries four addresses. Pick one.

## 8. Result (2026-11-22)
Functions 2196/2196 (main @ `ae81334` measured 2172, +12 SPK, +12 S5E1; S5E1-12 added by the PR #213 sweep), scripts 1199/1199. 30 hand mutants, 30 killed; one earlier mutant (`v >= 1` against `v > 0` in the picked-quantity guard) was equivalent after `Math.floor`, so the guard was simplified to `v > 0`. QML lint: brace balance clean on every touched file; the lint's style findings are the ones the same files already had (ORD-1, PRF-1, STY-3), no BND or loop finding is new, EXCEPT one new ORD-1 (`TextMetrics` before the property lines of `ChipScroller`), found and fixed in the PR #213 sweep (KNOWN-ISSUES 100). CI result is recorded in `CHECKPOINT.md` and the PR.

**The 30 mutants (each applied alone, then undone; the Node run of `pickerSpeech` + `pickerS5e1Wiring` had to fail):** price>=0; no floor; no dedup; canAdd loose; atMax loose; no trim; per->/; order; selected always; chip role; chip no press action; chip 40; row ignores pill; pill fixed 32; pillHeight fixed; metrics wrong font; emit before select; chipText not ignored; spoken dot; chip unchecked; tap differs; clear unnamed; clear 28; field unnamed; X unnamed; header grows; X 36; row drops qty; row drops price text; plus unnamed.

## 9. PR #213 review sweep (2026-11-22, same branch)
Skills: requesting-code-review, qt-qml-review, ponytail-audit, one agent, no parallel agents. Read the whole diff (18 files), ran the QML lint on the four changed components and diffed its findings against `main`, traced every `ChipScroller` and `SearchField` consumer, ran the baseline (functions 2195/2195, scripts 1199/1199). Fixed: F1 disabled chip press guard (S5E1-12, 3 of 3 mutants killed), F2 lint order, F3 check 141 currency text, F4 the lint claim above. Not fixed, written down: KNOWN-ISSUES 101, 102. Ponytail audit: nothing to delete; the explicit `Accessible.role: Accessible.Button` on two `AbstractButton`s is already the default role but pins intent against a style change and two tests assert it, so it stays (net 0 lines).

