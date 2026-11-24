# Product picker v2, slice S5f: delete five dead helpers, photo-sheet fonts through sp()

**Date:** 2026-11-24. **Branch:** `feat/2026-11-24-picker-s5f-dead-helper-cleanup`, cut from `main` @ `eaa0934` (#218 S5e-3c merged). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5f rows, device checks 203 to 208). **Closes:** KNOWN-ISSUES 121, 128; shrinks 143. **New:** KI 146, 147.

## 0. Where the roadmap stands (read from the repo, 2026-11-24)
Picker v2 S1 to S5e-3c merged (#185 to #218). Left on the roadmap: **this cleanup** (named by S5e-3c as its recommended follow-up, KI 143) and **S5e-4** (a curated device pass of about 20 checks, KI 29 decided with a number). S5e-4 is a phone job, not code. After this slice the picker v2 CODE is finished; what remains needs a phone.

## 1. What was measured (scripts, not memory)
| Question | Answer |
|---|---|
| Who uses `CardKPI`, `OrderRow`, `PlaceholderPage`, `SegmentedNav`, `StatusBadge`? | Nobody. `StatusBadge` was used only by `OrderRow`. No `qmldir`, `CMakeLists.txt` (it globs `qml/*.qml`), `main.cpp`, `src/` or `tests/` names them. 245 lines in total. |
| What did they cost? | 18 of the 25 bare pixel sizes, 44 of the 100 colour literals outside `Constants.qml`, the only unnamed icon buttons in the app (`OrderRow` x2) and one of the two unnamed text-child buttons (`SegmentedNav`): four ratchet exceptions in `pickerS5e3Names`, `pickerS5e3bNames`, `pickerS5e3cAudit`. |
| Any other QML file nothing uses? | **Yes, three** (found by the new scanner, comments stripped): `AuthPrimaryButton`, `AuthSecondaryButton` (dead, KI 146) and `AnalysisService` (dormant ON PURPOSE: README says "not yet wired into SalesPage"). A first scan that did not strip comments missed `AnalysisService`'s state and listed only two. |
| The 7 bare sizes on `PhotoSourceSheet` | 16 once, 14 x3, 11 x3. `Constants` already has the tokens: `fsTitle` 16, `fsBodyLg` 14, `fsCaption` 11. |
| What would a bigger font do to that sheet? | Its three rows are fixed at `implicitHeight: 56`. Two lines of text (14 bold + 11, 2 spacing) are about 32 px at normal size and about 62 px at 2.0x, so a scaled font would overflow the row border. |

## 2. Decisions (each has a default; veto in the PR)

**S5f-D1. Delete the five dead helpers, or keep them?** For: nothing uses them; each carries ratchet exceptions and accessibility debt (two unnamed icon buttons, bare sizes, colour literals); a dead file is read by every future audit. Against: someone may have meant to reuse them (they are "desktop-era" pieces); a deleted file is a small loss of intent. Git keeps them: `git show eaa0934:qml/helper/OrderRow.qml`. **Taken: delete (commit `686caf8`).** Veto = revert that commit alone; the guard test `S5F-01/02` then fails on purpose and says which file came back.

**S5f-D2. Wrap the seven photo-sheet sizes in `sp()` now?** For: the sheet is the only live screen that ignores the system font; every other text in the app goes through `sp()`. Against: the sheet is outside the picker arc, and `sp()` may paint a different size than the old bare number on a phone (Felgo's factor was never measured here: UNVERIFIED, KI 147). **Taken: do it, with a font TOKEN whose number equals the old size** (`S5F-09` fails if a token value moves), so the look at scale 1.0 is unchanged by construction. Own commit `b5e36b2`. Veto = revert it alone.

**S5f-D3. Let the rows grow.** A scaled font in a fixed 56 row overflows (section 1). **Taken: `implicitHeight: Math.max(56, <label column>.implicitHeight + 20)`.** The floor keeps today's 56 row for today's text (about 32 + 20 = 52, under 56); the row grows only when the text needs it. Rejected: leave 56 and hope (clips at about 1.8x); `Layout.minimumHeight` (these rows sit in a `ColumnLayout` that reads `implicitHeight`; the minimal change is the line that is already there). No binding loop: the column's height depends on its text, not on its parent row.

**S5f-D4. Delete the two dead Auth buttons found by the scanner?** Not named by the owner, and `pickerS5e3Names` lists them as named wrappers. **Taken: not here; KI 146 with a recommendation.** Scope stays what was planned.

**S5f-D5. Per-file guards or one generic ratchet?** One: `S5F-03` pins the exact set of unused QML files (today three, with the reason for each). The next dead file fails it. Cost: a QML file written ahead of its user (the repo's "dormant" pattern is JS, `AnalysisService` is the one QML case) fails it until the list is updated on purpose. That friction is the point.

**S5f-D6. What is NOT changed.** The 15 colour literals on the photo sheet (KI 143), the bare `size: 20` of its three `Icon`s (an icon glyph, not text, does not follow the font by design), the Auth fields' literals. No text, name, signal, anchor or handler changed.

## 3. What changed
- Commit A `686caf8`: five files deleted; tests `S5E3-05` (exception list now empty), `S5E3-06` (OrderRow gone, no mention), `S5E3-07` (one text-child button left, the ProductCard), `S5E3B-21`, `S5E3C-08` (2 invisible uncoloured texts), `S5E3C-10` (bare sizes), `S5E3C-12` (hex by file, minus 44); new `pickerS5fDeadHelpers.test.js` (`S5F-01..08`) and `testSupport/deadQmlScan.js`.
- Commit B `b5e36b2`: `PhotoSourceSheet.qml`: 7 sizes to `sp(Constants.fsTitle|fsBodyLg|fsCaption)`; three label `Column`s got ids (`camLabels`, `galLabels`, `remLabels`) and the three rows `Math.max(56, id.implicitHeight + 20)`; `S5E3C-10` now pins ZERO bare sizes in the app; `S5F-09..12`.
- 8 lines of QML, 2 files of ratchet fixes, 2 new files of tests, docs.

## 4. Test strategy
Node only (CI is the oracle, no Qt in the sandbox). `S5F-01` files gone. `S5F-02` no name in any QML file (comments stripped), `qmldir`, QML test, C++ or CMake. `S5F-03` the generic ratchet. `S5F-04` the live helpers survive. `S5F-05..07` the scanner on hand-built trees with decoys (self-mention, a comment, a longer name, a shorter name, a Loader string, C++ and CMake mentions, the `3rdparty` tree, empty tree, one file, nested directories). `S5F-08` a seeded monkey: 300 random trees with decoys, expected set known by construction. `S5F-09` the seven sizes are `sp(token)`, each token equals the old number. `S5F-10` the three rows, their ids, the 56 floor. `S5F-11` a seeded monkey that EVALUATES the row formula on 500 heights. `S5F-12` regression: labels, signals, 15 literals.
**Hand mutants:** 11 (raw 14 back, title token swapped, `+20` to `+0`, floor 56 to 40, id typo, `fsBodyLg` 15, a label reworded, a fixed 56 row back, an id removed, a hex literal ADDED, a dead helper restored); all killed. One "hex literal" mutant first SURVIVED because it changed a value instead of adding one (an equivalent mutant: the count did not move); redone as a real addition, killed.

## 5. What is NOT done (written down)
- Everything that needs a phone: checks 203 to 208. Not run. `sp()` versus the old bare size on a real device is UNVERIFIED (KI 147).
- `AuthPrimaryButton` and `AuthSecondaryButton` (KI 146).
- 56 colour literals outside `Constants.qml` (KI 143).
- **S5e-4** (the curated device pass, KI 29 with a number) is not code and not started.

## 6. Advice
1. **Run check 207 first** (start the app, open every page once). It is the only check that can catch a deleted type loaded by a computed string, which no source scan sees. The grep says none exists; the phone is the proof.
2. **S5e-4 is yours, on a phone, and it is the last picker item.** Make it 20 checks, not 208. Suggested set: New Order and Edit Order at 2.0x, TalkBack through the sheet, a dark phone (check 201), the photo sheet at 2.0x (check 205), KI 29 with one number. Write the result into the test plan, one line per check; the repo still holds no written device result for any S5e slice.
3. **Do not merge S5f and S5e-4 into one decision.** If the photo sheet looks different on your phone (KI 147), revert commit B only; the cleanup stays.

## 7. Questions for Taher (none block the merge)
- **Q1.** Delete the five dead helpers? Default: yes (veto = revert `686caf8`).
- **Q2.** Keep the photo-sheet `sp()` and the growing rows? Default: yes (veto = revert `b5e36b2`).
- **Q3.** Delete `AuthPrimaryButton` and `AuthSecondaryButton` (KI 146) in the next cleanup? Default: yes, own slice.
- **Q4.** Commit address: this session used `taher.lkdw@gmail.com` (owner instruction of 2026-11-24).

## 8. Result (2026-11-24)
New Node tests 12 (`S5F-01..12`) plus the new support file that `node --test` also runs; functions suite 2404/2404 (main @ `eaa0934` was 2391), scripts 1199/1199, `skills-index.js --check` current after Skill 190. Hand mutants 11, all killed. Not run: CI (read on the PR head), any device check (203 to 208).
